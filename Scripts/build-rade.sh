#!/bin/bash
# Builds Vendor/rade/FTX1Rade.xcframework: FreeDV's RADE V1 receiver and
# transmitter for the Mac app's Tools → FreeDV window, as one universal (arm64 + x86_64) static
# library behind a single header (Scripts/rade/ftx1_rade.h).
#
# What goes in, all pinned by commit and checked by sha256:
#   - rade_c (freedv/rade_c, BSD-2): the RADE V1 modem + neural decoder,
#     weights compiled in. Only V1: the V2 sources and weights are left out
#     and Scripts/rade/rade_v2_stubs.c stands in for the V2 calls rade_api.c
#     makes (it never makes them for a V1 receiver).
#   - Opus at the commit rade_c's cmake/BuildOpus.cmake pins (xiph/opus,
#     BSD-3), configured as rade_c does (OSCE + DRED, which builds FARGAN),
#     with rade_c's nnet.h/nnet.c patch, plus the model data Opus's
#     autogen.sh fetches (opus_data-<sha256>.tar.gz from media.xiph.org).
#   - freedv-backend's end-of-over callsign code (freedv/freedv-backend,
#     BSD-2): src/pipeline/rade_text.cpp, ldpc_encode/decode.cpp and
#     HRA_56_56.h, with Scripts/rade/ulog.h in place of its logger. This is
#     what the FreeDV app sends on the air; rade_c's own 7-bit test packing
#     isn't.
#   - Scripts/rade/ftx1_rade.c, our wrapper (the only API Swift sees).
#
# Downloads go to releases/rade-sources/ (gitignored) and are reused. All of
# it is BSD-licensed, so unlike Hamlib there's no source to attach to
# releases; the three licences are copied next to the xcframework and listed
# in the README's "Third-party code".
#
# Usage: Scripts/build-rade.sh
#   To move to a new rade_c: set RADE_COMMIT, run once with the new value to
#   see the archive's sha256, check it, set RADE_SHA256; take OPUS_COMMIT
#   from that commit's cmake/BuildOpus.cmake and OPUS_MODEL_SHA256 from its
#   Opus autogen.sh the same way. Then rerun the FreeDVKit tests.

set -euo pipefail

RADE_COMMIT="23c3746e488dd4825178b4abb857106a5f61a4e6"            # 2026-11-20
RADE_SHA256="e2eb9e7973032a8abc37d465273c0232acd153cb42faf8a824129c4c8e11908e"
OPUS_COMMIT="940d4e5af64351ca8ba8390df3f555484c567fbb"
OPUS_SHA256="285c74f5130ee074f123aaad81cd52c2fc8db653ee130941afafe3ee0ae8cec2"
OPUS_MODEL_SHA256="4ed9445b96698bad25d852e912b41495ddfa30c8dbc8a55f9cde5826ed793453"
BACKEND_COMMIT="49006b029853061ca4e992f9632a51875aa3ecf1"         # 2026-11-12
BACKEND_SHA256="d8d8e158f770c9dd26b870a40c6562affae9cd5cda7d87bb6ef21382470d7cc7"
# Matches the Mac target's MACOSX_DEPLOYMENT_TARGET.
DEPLOYMENT_TARGET="26.5"
ARCHS=(arm64 x86_64)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER_DIR="$REPO_ROOT/Scripts/rade"
CACHE="$REPO_ROOT/releases/rade-sources"
OUT_DIR="$REPO_ROOT/Vendor/rade"
JOBS="$(sysctl -n hw.ncpu)"

# Homebrew's libtool installs libtoolize as glibtoolize (macOS has its own libtool).
for tool in autoreconf automake glibtoolize curl; do
  command -v "$tool" >/dev/null || {
    echo "error: $tool not found (brew install autoconf automake libtool)" >&2; exit 1; }
done

# fetch <url> <file> <sha256>: download into the cache unless present, then check.
fetch() {
  local url="$1" file="$CACHE/$2" expected="$3"
  mkdir -p "$CACHE"
  if [ ! -f "$file" ]; then
    echo "==> Downloading $2"
    curl -fsSL -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local actual
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "error: $2 has sha256 $actual, expected $expected" >&2
    exit 1
  fi
}

fetch "https://github.com/freedv/rade_c/archive/$RADE_COMMIT.tar.gz" \
  "rade_c-$RADE_COMMIT.tar.gz" "$RADE_SHA256"
fetch "https://github.com/xiph/opus/archive/$OPUS_COMMIT.tar.gz" \
  "opus-$OPUS_COMMIT.tar.gz" "$OPUS_SHA256"
fetch "https://media.xiph.org/opus/models/opus_data-$OPUS_MODEL_SHA256.tar.gz" \
  "opus_data-$OPUS_MODEL_SHA256.tar.gz" "$OPUS_MODEL_SHA256"
fetch "https://github.com/freedv/freedv-backend/archive/$BACKEND_COMMIT.tar.gz" \
  "freedv-backend-$BACKEND_COMMIT.tar.gz" "$BACKEND_SHA256"

WORK="$(mktemp -d -t build-rade)"
trap 'rm -rf "$WORK"' EXIT
echo "==> Unpacking"
tar -xzf "$CACHE/rade_c-$RADE_COMMIT.tar.gz" -C "$WORK"
tar -xzf "$CACHE/freedv-backend-$BACKEND_COMMIT.tar.gz" -C "$WORK"
RADE="$WORK/rade_c-$RADE_COMMIT"
BACKEND="$WORK/freedv-backend-$BACKEND_COMMIT"

# rade_c's V1 library sources (its src/CMakeLists.txt minus the V2 lists).
RADE_SOURCES=(rade_api.c rade_enc.c rade_dec.c rade_enc_data.c rade_dec_data.c
              rade_dsp.c rade_ofdm.c rade_bpf.c rade_acq.c rade_tx.c rade_rx.c)
TEXT_SOURCES=(rade_text.cpp ldpc_encode.cpp ldpc_decode.cpp)

# freedv-backend's sources include "../util/logging/ulog.h"; give them ours.
TEXT_DIR="$WORK/text/pipeline"
mkdir -p "$TEXT_DIR" "$WORK/text/util/logging"
cp "$WRAPPER_DIR/ulog.h" "$WORK/text/util/logging/ulog.h"
for f in "${TEXT_SOURCES[@]}" rade_text.h ldpc_encode.h ldpc_decode.h HRA_56_56.h; do
  cp "$BACKEND/src/pipeline/$f" "$TEXT_DIR/"
done

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
for ARCH in "${ARCHS[@]}"; do
  echo "==> Opus ($ARCH)"
  OPUS="$WORK/opus-$ARCH"
  mkdir -p "$OPUS"
  tar -xzf "$CACHE/opus-$OPUS_COMMIT.tar.gz" -C "$OPUS" --strip-components 1
  cp "$CACHE/opus_data-$OPUS_MODEL_SHA256.tar.gz" "$OPUS/"
  (
    cd "$OPUS"
    patch -s dnn/nnet.h < "$RADE/src/opus-nnet.h.diff"
    patch -s dnn/nnet.c < "$RADE/src/opus-nnet.c.diff"
    # autogen.sh finds the model tarball already in place (checked above).
    ./autogen.sh > autogen.log 2>&1 || { tail -40 autogen.log >&2; exit 1; }
    ./configure --with-pic --enable-osce --enable-dred --disable-shared \
      --disable-doc --disable-extra-programs \
      --host="$ARCH-apple-darwin" \
      CC="clang -arch $ARCH" \
      CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      > configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }
    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
  )

  echo "==> rade_c + callsign + wrapper ($ARCH)"
  OBJ="$WORK/obj-$ARCH"
  mkdir -p "$OBJ"
  INC=(-I"$RADE/src" -I"$OPUS/include" -I"$OPUS/dnn" -I"$OPUS/celt" -I"$OPUS"
       -I"$TEXT_DIR" -I"$WRAPPER_DIR")
  CFLAGS=(-arch "$ARCH" -O3 -DNDEBUG -mmacosx-version-min="$DEPLOYMENT_TARGET" -w)
  pids=()
  for f in "${RADE_SOURCES[@]}"; do
    clang -std=c11 "${CFLAGS[@]}" "${INC[@]}" -c "$RADE/src/$f" -o "$OBJ/${f%.c}.o" & pids+=($!)
  done
  for f in "${TEXT_SOURCES[@]}"; do
    clang++ -std=c++17 "${CFLAGS[@]}" "${INC[@]}" -c "$TEXT_DIR/$f" -o "$OBJ/${f%.cpp}.o" & pids+=($!)
  done
  clang -std=c11 "${CFLAGS[@]}" "${INC[@]}" -c "$WRAPPER_DIR/ftx1_rade.c" -o "$OBJ/ftx1_rade.o" & pids+=($!)
  clang -std=c11 "${CFLAGS[@]}" -c "$WRAPPER_DIR/rade_v2_stubs.c" -o "$OBJ/rade_v2_stubs.o" & pids+=($!)
  for p in "${pids[@]}"; do wait "$p"; done

  libtool -static -o "$WORK/libFTX1Rade-$ARCH.a" "$OBJ"/*.o "$OPUS/.libs/libopus.a" 2>/dev/null
done

echo "==> Merging and packaging"
SLICES=()
for ARCH in "${ARCHS[@]}"; do SLICES+=("$WORK/libFTX1Rade-$ARCH.a"); done
lipo -create "${SLICES[@]}" -output "$WORK/libFTX1Rade.a"
# Debug symbols only bloat the repo copy; the app's own link strips the rest.
strip -S "$WORK/libFTX1Rade.a" 2>/dev/null

HEADERS="$WORK/Headers"
mkdir -p "$HEADERS"
cp "$WRAPPER_DIR/ftx1_rade.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module CFTX1Rade {
    header "ftx1_rade.h"
    link "c++"
    export *
}
EOF

# Link-check: every symbol the wrapper needs must resolve inside the
# library, so nothing outside libSystem/libc++ is needed at app link time.
cat > "$WORK/check.c" <<'EOF'
#include "ftx1_rade.h"
#include <stdio.h>
int main(void) {
    ftx1_rade_rx *rx = ftx1_rade_rx_open();
    if (!rx) return 1;
    printf("rade_c API %d, wrapper %d, nin_max %d, speech_max %d\n",
           ftx1_rade_rade_version(), ftx1_rade_wrapper_version(),
           ftx1_rade_rx_nin_max(rx), ftx1_rade_rx_speech_max(rx));
    ftx1_rade_rx_close(rx);
    ftx1_rade_tx *tx = ftx1_rade_tx_open();
    if (!tx) return 1;
    printf("    tx modem_max %d, finish_max %d\n", ftx1_rade_tx_modem_max(tx), ftx1_rade_tx_finish_max(tx));
    ftx1_rade_tx_close(tx);
    return 0;
}
EOF
for ARCH in "${ARCHS[@]}"; do
  clang -arch "$ARCH" -mmacosx-version-min="$DEPLOYMENT_TARGET" -I"$HEADERS" \
    "$WORK/check.c" "$WORK/libFTX1Rade.a" -lc++ -o "$WORK/check-$ARCH"
  echo -n "    $ARCH: "
  arch -"$ARCH" "$WORK/check-$ARCH"
done

rm -rf "$OUT_DIR/FTX1Rade.xcframework"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework -library "$WORK/libFTX1Rade.a" -headers "$HEADERS" \
  -output "$OUT_DIR/FTX1Rade.xcframework" > /dev/null
cp "$RADE/LICENSE" "$OUT_DIR/LICENSE-rade_c.txt"
cp "$WORK/opus-arm64/COPYING" "$OUT_DIR/LICENSE-opus.txt"
cp "$BACKEND/LICENSE" "$OUT_DIR/LICENSE-freedv-backend.txt"
cat > "$OUT_DIR/VERSIONS.txt" <<EOF
Built by Scripts/build-rade.sh
rade_c          $RADE_COMMIT
opus            $OPUS_COMMIT (model data $OPUS_MODEL_SHA256)
freedv-backend  $BACKEND_COMMIT
deployment      macOS $DEPLOYMENT_TARGET, ${ARCHS[*]}
EOF

lipo -info "$OUT_DIR/FTX1Rade.xcframework"/*/libFTX1Rade.a
echo "Done: $OUT_DIR/FTX1Rade.xcframework ($(du -sh "$OUT_DIR/FTX1Rade.xcframework" | cut -f1))"
