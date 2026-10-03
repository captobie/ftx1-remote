"""Convert CWKit's neural CW model (CWNet.mlmodelc) to ONNX for the Windows app.

The Mac app runs the model through Core ML, straight from CWKit (captobie/cwdecode,
Sources/CWKit/Resources/CWNet.mlmodelc). Windows has no Core ML, so this script turns that
same compiled model into CWNet.onnx, run with ONNX Runtime by Services/CwNetModel.cs. The
weights are copied as they are, so both apps run the identical network; cwdecode stays the
source of truth. Rerun this whenever CWKit ships a new model, and check the result with
--check against that release's golden file.

An .mlmodelc holds an ML Program: model.mil (the program as text) and weights/weight.bin.
model.mil is parsed generically, but only the handful of ops CWNet uses are supported (conv,
relu, add, reduce_max, transpose, softmax, log); anything else stops the conversion rather
than producing a wrong model. weight.bin is a list of blobs, each a 64-byte header
(0xDEADBEEF, data type, size, data offset) followed by its raw little-endian data.

Usage (Python 3.9+, `pip install numpy onnx onnxruntime`):

    python cwnet_to_onnx.py --tag 0.1.1
    python cwnet_to_onnx.py --mlmodelc <path to CWNet.mlmodelc> --golden <path to golden.json>

--tag downloads the model and golden.json from that cwdecode release on GitHub. The output
defaults to ../FTX1RemoteWindows/Assets/CWNet.onnx. --check (on by default when golden.json
is available) runs the converted model on golden.json's spectrogram and compares it with the
Python reference's log-probabilities, the same test as CWKit's modelMatchesPython.
"""
import argparse
import json
import re
import struct
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

HERE = Path(__file__).resolve().parent
DEFAULT_OUTPUT = HERE.parent / "FTX1RemoteWindows" / "Assets" / "CWNet.onnx"
RAW = "https://raw.githubusercontent.com/captobie/cwdecode/{tag}/{path}"
MODEL_FILES = ["model.mil", "metadata.json", "weights/weight.bin"]
MODEL_DIR = "Sources/CWKit/Resources/CWNet.mlmodelc"
GOLDEN = "Tests/CWKitTests/Resources/Neural/golden.json"
# CWNet's op set: anything outside it is refused rather than guessed at.
SUPPORTED = {"const", "conv", "relu", "add", "reduce_max", "transpose", "softmax", "log"}
BLOB_SENTINEL = 0xDEADBEEF
BLOB_FP32 = 2


def download(tag: str, workdir: Path):
    model = workdir / "CWNet.mlmodelc"
    for name in MODEL_FILES:
        target = model / name
        target.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(RAW.format(tag=tag, path=f"{MODEL_DIR}/{name}"), target)
    golden = workdir / "golden.json"
    urllib.request.urlretrieve(RAW.format(tag=tag, path=GOLDEN), golden)
    return model, golden


def read_blob(weights: bytes, offset: int, shape):
    sentinel, dtype, size, data_offset = struct.unpack_from("<IIQQ", weights, offset)
    if sentinel != BLOB_SENTINEL:
        raise ValueError(f"no weight blob at offset {offset}")
    if dtype != BLOB_FP32:
        raise ValueError(f"weight blob at {offset} has data type {dtype}, only float32 is supported")
    values = np.frombuffer(weights, dtype="<f4", count=size // 4, offset=data_offset)
    return values.reshape(shape).astype(np.float32)


def parse_shape(text: str):
    return [None if d.strip() == "?" else int(d) for d in text.split(",") if d.strip()]


def parse_literal(text: str, weights: bytes):
    """A const's val: BLOBFILE, a tensor/list literal, or a scalar."""
    text = text.strip()
    blob = re.match(r"tensor<fp32, \[([^\]]*)\]>\(BLOBFILE\(path = string\(\"[^\"]*\"\), offset = uint64\((\d+)\)\)\)", text)
    if blob:
        return read_blob(weights, int(blob.group(2)), parse_shape(blob.group(1)))
    tensor = re.match(r"tensor<(\w+), \[[^\]]*\]>\(\[([^\]]*)\]\)", text)
    if tensor:
        kind, values = tensor.groups()
        items = [v.strip() for v in values.split(",") if v.strip()]
        return [int(v) for v in items] if kind.startswith("int") else [float.fromhex(v) if "0x" in v else float(v) for v in items]
    scalar = re.match(r"(\w+)\((.*)\)$", text)
    if scalar:
        kind, value = scalar.groups()
        if kind == "string":
            return value.strip('"')
        if kind == "bool":
            return value == "true"
        if kind.startswith("int"):
            return int(value)
        if kind.startswith("fp"):
            return float.fromhex(value) if "0x" in value else float(value)
    raise ValueError(f"can't read constant {text!r}")


LINE = re.compile(r"^\s*(?P<type>.+?) (?P<name>\w+) = (?P<op>\w+)\((?P<args>.*)\)\[name = string\(\"[^\"]*\"\)(?:, val = (?P<val>.*))?\];$")


def parse_program(mil: str, weights: bytes):
    """Returns (input name, input shape, ops, constants, output name)."""
    signature = re.search(r"func main<\w+>\(tensor<fp32, \[([^\]]*)\]> (\w+)\)", mil)
    if not signature:
        raise ValueError("no main function with one float32 tensor input")
    input_shape, input_name = parse_shape(signature.group(1)), signature.group(2)
    output = re.search(r"\} -> \((\w+)\);", mil)
    if not output:
        raise ValueError("no single program output")
    constants, ops = {}, []
    body = mil[signature.end():output.start()]
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("{") or line.startswith("}") or line.startswith("[") or line.startswith("func"):
            continue
        match = LINE.match(line)
        if not match:
            continue
        op, name = match.group("op"), match.group("name")
        if op not in SUPPORTED:
            raise ValueError(f"op {op!r} ({name}) isn't supported by this converter")
        if op == "const":
            constants[name] = parse_literal(match.group("val"), weights)
            continue
        args = dict(re.findall(r"(\w+) = (\w+)", match.group("args")))
        ops.append((op, name, args))
    return input_name, input_shape, ops, constants, output.group(1)


def build_onnx(input_name, input_shape, ops, constants, output_name, metadata):
    nodes, initializers = [], []
    used_initializers = set()

    def tensor_input(var):
        """An op argument: a constant tensor becomes an initializer, a variable stays a name."""
        if var in constants and isinstance(constants[var], np.ndarray):
            if var not in used_initializers:
                initializers.append(numpy_helper.from_array(constants[var], var))
                used_initializers.add(var)
        return var

    def const(var):
        return constants[var]

    for op, name, args in ops:
        if op == "conv":
            weight = const(args["weight"])
            spatial = weight.ndim - 2
            pad_type = const(args["pad_type"])
            if pad_type == "custom":
                pad = const(args["pad"])  # MIL: [begin, end] per spatial axis
                pads = [pad[2 * i] for i in range(spatial)] + [pad[2 * i + 1] for i in range(spatial)]
            elif pad_type == "valid":
                pads = [0] * (2 * spatial)
            else:
                raise ValueError(f"conv {name}: pad_type {pad_type!r} isn't supported")
            inputs = [args["x"], tensor_input(args["weight"])]
            if "bias" in args:
                inputs.append(tensor_input(args["bias"]))
            nodes.append(helper.make_node(
                "Conv", inputs, [name], name=name,
                kernel_shape=list(weight.shape[2:]), strides=const(args["strides"]),
                dilations=const(args["dilations"]), group=const(args["groups"]), pads=pads))
        elif op == "relu":
            nodes.append(helper.make_node("Relu", [args["x"]], [name], name=name))
        elif op == "add":
            nodes.append(helper.make_node("Add", [args["x"], args["y"]], [name], name=name))
        elif op == "reduce_max":
            nodes.append(helper.make_node("ReduceMax", [args["x"]], [name], name=name,
                                          axes=const(args["axes"]), keepdims=int(const(args["keep_dims"]))))
        elif op == "transpose":
            nodes.append(helper.make_node("Transpose", [args["x"]], [name], name=name, perm=const(args["perm"])))
        elif op == "softmax":
            nodes.append(helper.make_node("Softmax", [args["x"]], [name], name=name, axis=const(args["axis"])))
        elif op == "log":
            # MIL's log takes an epsilon: log(x + epsilon).
            epsilon_name = f"{name}_epsilon"
            initializers.append(numpy_helper.from_array(np.array(const(args["epsilon"]), dtype=np.float32), epsilon_name))
            nodes.append(helper.make_node("Add", [args["x"], epsilon_name], [f"{name}_shifted"], name=f"{name}_shift"))
            nodes.append(helper.make_node("Log", [f"{name}_shifted"], [name], name=name))

    dims = [d if d is not None else "frames" for d in input_shape]
    graph = helper.make_graph(
        nodes, "CWNet",
        [helper.make_tensor_value_info(input_name, TensorProto.FLOAT, dims)],
        [helper.make_tensor_value_info(output_name, TensorProto.FLOAT, [1, "output_frames", None])],
        initializers)
    # Opset 17: ReduceMax still takes its axes as an attribute there.
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)],
                              producer_name="ftx1-remote cwnet_to_onnx.py")
    model.ir_version = 8
    for key, value in metadata.items():
        entry = model.metadata_props.add()
        entry.key, entry.value = key, value
    onnx.checker.check_model(model)
    return model


def check(model_path: Path, golden_path: Path) -> bool:
    import onnxruntime as ort

    golden = json.loads(golden_path.read_text(encoding="utf-8"))
    clip = golden["clips"]["features"]
    spectrogram = clip["spectrogram"]
    x = np.array(spectrogram["values"], dtype=np.float32).reshape(1, 1, spectrogram["bins"], spectrogram["frames"])
    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    log_probs = session.run(None, {session.get_inputs()[0].name: x})[0]
    head = np.array(clip["log_probs_head"], dtype=np.float32)
    frames_ok = log_probs.shape[1] == clip["output_frames"]
    worst = float(np.max(np.abs(np.exp(log_probs[0, :head.shape[0], :]) - np.exp(head))))
    # CWKit's modelMatchesPython: probabilities within 1e-3.
    ok = frames_ok and worst < 1e-3
    print(f"check: output frames {log_probs.shape[1]} (expected {clip['output_frames']}), "
          f"largest probability difference {worst:.2e} -> {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--tag", help="cwdecode release tag to download, e.g. 0.1.1")
    source.add_argument("--mlmodelc", type=Path, help="path to a local CWNet.mlmodelc")
    parser.add_argument("--golden", type=Path, help="golden.json for --check (downloaded with --tag)")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--no-check", action="store_true")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        if args.tag:
            model_dir, golden = download(args.tag, Path(tmp))
            source_label = f"cwdecode {args.tag}"
        else:
            model_dir, golden = args.mlmodelc, args.golden
            source_label = str(args.mlmodelc)

        mil = (model_dir / "model.mil").read_text(encoding="utf-8")
        weights = (model_dir / "weights" / "weight.bin").read_bytes()
        core_ml = json.loads((model_dir / "metadata.json").read_text(encoding="utf-8"))[0]
        user = core_ml.get("userDefinedMetadata", {})
        if "vocabulary" not in user or "features" not in user:
            sys.exit("metadata.json has no vocabulary/features: not a CWNet model")
        metadata = dict(user)
        metadata["model_version"] = core_ml.get("version", "")
        metadata["converted_from"] = f"{source_label} CWNet.mlmodelc"

        model = build_onnx(*parse_program(mil, weights), metadata=metadata)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        onnx.save(model, args.output)
        print(f"wrote {args.output} ({args.output.stat().st_size} bytes, model version {metadata['model_version']}, "
              f"{len(json.loads(user['vocabulary']))} tokens)")

        if not args.no_check:
            if golden is None:
                print("check: skipped (no --golden)")
            elif not check(args.output, golden):
                sys.exit(1)


if __name__ == "__main__":
    main()
