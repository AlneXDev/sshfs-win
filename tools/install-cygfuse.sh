#!/bin/sh
# Install WinFsp's FUSE2 + FUSE3 packages into the current Cygwin installation.
# Run this from a Cygwin shell with admin rights (it writes to /usr).
set -eu

REG=/proc/registry32/HKEY_LOCAL_MACHINE/SOFTWARE/WinFsp/InstallDir
if [ ! -f "$REG" ]; then
    echo "ERROR: WinFsp does not appear to be installed (registry key missing)." >&2
    exit 1
fi

WINFSP=$(tr -d '\0' < "$REG")
WINFSP_POSIX=$(cygpath -u "$WINFSP")
echo "WinFsp install dir: $WINFSP_POSIX"

if [ ! -f "$WINFSP_POSIX/opt/cygfuse/install.sh" ]; then
    echo "ERROR: $WINFSP_POSIX/opt/cygfuse/install.sh not found." >&2
    echo "Use tools/build-local-cygfuse.sh, or reinstall WinFsp with the full developer feature set." >&2
    exit 1
fi

sh "$WINFSP_POSIX/opt/cygfuse/install.sh"

echo "Installed. Verify with:"
echo "  pkg-config --modversion fuse3"
