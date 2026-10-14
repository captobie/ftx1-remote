#!/bin/bash
# Builds the rigctld the Mac app bundles as its fallback (Contents/Helpers/
# rigctld): a static, self-contained, universal (arm64 + x86_64) binary
# from Hamlib's own release tarball, which ships a generated ./configure
# (a git checkout would need automake/libtool to bootstrap).
#
# Writes Vendor/hamlib/rigctld plus Hamlib's licence files (COPYING,
# COPYING.LIB, LICENSE), which the app ships next to it. The same tarball
# has to be attached to every GitHub release that ships this binary
# (GPL-2.0+ source offer) — see CLAUDE.md "Bundled rigctld".
#
# Usage: Scripts/build-rigctld.sh <path/to/hamlib-X.Y.Z.tar.gz> [sha256]
#   Download the tarball (not GitHub's "Source code" archives) from
#   https://github.com/Hamlib/Hamlib/releases. The checksum defaults to the
#   one for HAMLIB_VERSION below; pass the release page's sha256 for
#   another version.

set -euo pipefail

HAMLIB_VERSION="4.7.2"
DEFAULT_SHA256="ae1fcf2dbc80ea0786ea8f047b09399c3f7737d1930442f61a031708ed33e88f"
# Matches the Mac target's MACOSX_DEPLOYMENT_TARGET.
DEPLOYMENT_TARGET="26.5"
ARCHS=(arm64 x86_64)

TARBALL="${1:?usage: $0 <hamlib-X.Y.Z.tar.gz> [sha256]}"
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
EXPECTED_SHA256="${2:-$DEFAULT_SHA256}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Vendor/hamlib"

echo "==> Checking $(basename "$TARBALL")"
ACTUAL_SHA256=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "error: sha256 $ACTUAL_SHA256, expected $EXPECTED_SHA256" >&2
  exit 1
fi

WORK="$(mktemp -d -t build-rigctld)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$TARBALL" -C "$WORK"
SRC="$(echo "$WORK"/hamlib-*)"

# Keep Homebrew/MacPorts out of the build: pkg-config would otherwise find
# their libraries (libusb, libgd, INDI) and link them dynamically.
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$WORK/no-pkgconfig"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

for ARCH in "${ARCHS[@]}"; do
  echo "==> Building $ARCH"
  BUILD="$WORK/build-$ARCH"
  mkdir -p "$BUILD"
  (
    cd "$BUILD"
    "$SRC/configure" \
      --host="$ARCH-apple-darwin" \
      --disable-shared --enable-static \
      --without-libusb --without-readline --without-indi \
      --without-cxx-binding --without-xml-support \
      --disable-html-matrix --disable-dependency-tracking \
      CC="clang -arch $ARCH" CXX="clang++ -arch $ARCH" \
      CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET" \
      > configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }
    # The whole tree: libhamlib.la pulls in every backend's convenience
    # library, which the top-level SUBDIRS order builds first.
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
  )
  # tests/rigctld is a plain binary here (no libtool wrapper script) since
  # there are no shared libraries to point it at.
  cp "$BUILD/tests/rigctld" "$WORK/rigctld-$ARCH"
done

echo "==> Merging into a universal binary"
mkdir -p "$OUT_DIR"
lipo -create "${ARCHS[@]/#/$WORK/rigctld-}" -output "$OUT_DIR/rigctld"
strip -x "$OUT_DIR/rigctld"
cp "$SRC/COPYING" "$SRC/COPYING.LIB" "$SRC/LICENSE" "$OUT_DIR/"

echo "==> Checking the result"
lipo -info "$OUT_DIR/rigctld"
vtool -show-build "$OUT_DIR/rigctld" | grep -E 'architecture|minos'
# Library lines are tab-indented; the rest are per-architecture headers.
if otool -L "$OUT_DIR/rigctld" | grep -E '^\s' | grep -v -E '^\s+/usr/lib/|^\s+/System/Library/'; then
  echo "error: rigctld links a non-system library (above)" >&2
  exit 1
fi
"$OUT_DIR/rigctld" --version
if ! "$OUT_DIR/rigctld" -l | grep -qE '^\s*1051\s'; then
  echo "error: rigctld -l doesn't list model 1051 (FTX-1)" >&2
  exit 1
fi
echo "Done: $OUT_DIR/rigctld ($(du -h "$OUT_DIR/rigctld" | cut -f1)), Hamlib $HAMLIB_VERSION"
