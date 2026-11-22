#!/bin/sh
# Build WinFsp's FUSE3-for-Cygwin shim locally.
#
# Use this when your WinFsp install has no opt/cygfuse/install.sh (common with
# winget / SxS-only installs). It needs only curl, tar and gcc from Cygwin.
#
# Usage (Cygwin shell):
#   sh tools/build-local-cygfuse.sh [PREFIX]
#
# Then build with:
#   export PATH="$PREFIX/bin:$PATH"
#   export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
#   make
set -eu

PREFIX=${1:-/usr/local/fuse3win}
# Pinned to WinFsp v2.2 so the shim build is reproducible. Override with
# SRCURL=... if you need a different WinFsp revision.
SRCURL=${SRCURL:-https://codeload.github.com/winfsp/winfsp/tar.gz/ada6de157df4fa99f5a866b6ac7af66918d6d838}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Downloading WinFsp source..."
# Windows' native curl.exe may shadow Cygwin's curl; give it a Windows path.
curl -fsSL "$SRCURL" -o "$(cygpath -w "$WORK/winfsp.tar.gz")"
tar -xzf "$WORK/winfsp.tar.gz" -C "$WORK"
SRC=$(find "$WORK" -maxdepth 1 -type d -name 'winfsp-*' | head -n 1)
test -f "$SRC/opt/cygfuse/fuse3/cygfuse.c" || {
    echo "ERROR: WinFsp source layout unexpected" >&2
    exit 1
}

VERSION=$(sed -n '/^VERSION=/s/VERSION=\(.*\)/\1/p' \
    "$SRC/opt/cygfuse/fuse3/fuse3.cygport")
test -n "$VERSION" || VERSION=3.2

echo "Installing FUSE $VERSION headers and shim into $PREFIX"
mkdir -p "$PREFIX/include" "$PREFIX/bin" "$PREFIX/lib/pkgconfig"
cp -r "$SRC/inc/fuse3" "$SRC/inc/fuse" "$SRC/inc/winfsp" "$PREFIX/include/"

gcc -O2 -shared -o "$PREFIX/bin/cygfuse-$VERSION.dll" \
    -Wl,--out-implib="$PREFIX/lib/libfuse-$VERSION.dll.a" \
    -I"$PREFIX/include/fuse3" \
    "$SRC/opt/cygfuse/fuse3/cygfuse.c"

cat > "$PREFIX/lib/pkgconfig/fuse3.pc" <<EOF
prefix=$PREFIX
incdir=\${prefix}/include/fuse3
Name: fuse
Description: WinFsp FUSE3 compatibility layer (local build)
Version: $VERSION
URL: https://winfsp.dev
Libs: -L\${prefix}/lib -lfuse-$VERSION
Cflags: -I"\${incdir}" -DCYGFUSE
EOF

echo
echo "Done. Build sshfs with:"
printf '  export PATH="%s/bin:$PATH"\n' "$PREFIX"
printf '  export PKG_CONFIG_PATH="%s/lib/pkgconfig"\n' "$PREFIX"
echo "  make"
echo
echo "Verify: pkg-config --modversion fuse3"
