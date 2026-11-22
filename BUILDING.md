# Building SSHFS 3.7.7 for Windows

This project builds **stock upstream [libfuse/sshfs](https://github.com/libfuse/sshfs)
3.7.7** on Windows, with only three small Windows-specific patches applied on top.
It follows the same architecture as [SSHFS-Win](https://github.com/winfsp/sshfs-win),
but targets current upstream and WinFsp's **FUSE3** compatibility layer.

```
 net use / Explorer  --->  WinFsp launcher service  --->  sshfs-win.exe  --->  sshfs.exe
                                                              |                |
                                                              |                +-- SFTP over ssh
                                                              |                    (Cygwin OpenSSH)
                                                              +-- WinFsp FUSE3 emulation (cygfuse-3.2.dll)
                                                                       |
                                                                       +-- WinFsp FSD (kernel driver)
```

Cygwin supplies the POSIX runtime (pthreads, GLib, `realpath`, `fork`, signals, etc.).
WinFsp supplies the kernel filesystem driver plus a FUSE3-compatible DLL. No Linux
kernel, WSL, or MSVC build of sshfs is involved.

## 1. Prerequisites

| Component | Purpose | Notes |
|---|---|---|
| [WinFsp](https://winfsp.dev/rel/) | Kernel FSD + FUSE2/FUSE3 emulation | The full MSI provides `opt/cygfuse/install.sh`. A winget/SxS install lacks it, so use `tools/build-local-cygfuse.sh` instead (the FSD and DLL are already present). |
| Cygwin x86_64 (or x86) | POSIX runtime | `C:\cygwin64` recommended |
| Cygwin packages | Toolchain + SSH client | `gcc-core`, `make`, `meson`, `ninja`, `patch`, `pkg-config`, `libglib2.0-devel`, **`openssh`** (provides `/usr/bin/ssh.exe`, which the launcher invokes), `git` (optional) |
| [WiX Toolset v3](https://github.com/wixtoolset/wix3/releases) | Optional, MSI installer | Only needed for `make msi`; set `%WIX%` to e.g. `C:\Program Files (x86)\WiX Toolset v3.14` |

Quick install (PowerShell, as administrator):

```powershell
winget install WinFsp.WinFsp
winget install Cygwin.Cygwin --location "C:\cygwin64"
```

Then run Cygwin's `setup-x86_64.exe` once with these extra packages:

```
gcc-core make meson ninja patch pkg-config libglib2.0-devel openssh
```

> **Note:** `meson` and `ninja` from Cygwin are Python-based wrappers that work inside
> the Cygwin shell. Do not run `make` from PowerShell/cmd.

## 2. Install FUSE-for-Cygwin (FUSE3 layer)

WinFsp ships a Cygwin package containing `fuse3.pc`, `fuse.h` and
`cygfuse-3.2.dll`. Install it into the Cygwin tree:

```sh
WINFSP=$(cat /proc/registry32/HKEY_LOCAL_MACHINE/SOFTWARE/WinFsp/InstallDir | tr -d '\0')
sh "$WINFSP/opt/cygfuse/install.sh"
```

Verify that Cygwin can now find FUSE3:

```sh
pkg-config --modversion fuse3     # should print 3.2
pkg-config --cflags --libs fuse3  # -I/usr/include/fuse3 -DCYGFUSE -lfuse-3.2
test -f /usr/include/fuse3/fuse.h && echo "FUSE3 headers OK"
```

`fuse3.pc` reports version **3.2**, which satisfies upstream sshfs 3.7.7's
`dependency('fuse3', version: '>= 3.1.0')`.

If `install.sh` is missing, your WinFsp install is runtime-only (this is common
with winget installs). You have two options:

1. Re-run the full WinFsp installer and select the complete/developer feature set.
2. Build just the FUSE3 shim yourself from WinFsp source (no admin needed):

```sh
sh tools/build-local-cygfuse.sh           # installs to /usr/local/fuse3win
export PATH="/usr/local/fuse3win/bin:$PATH"
export PKG_CONFIG_PATH="/usr/local/fuse3win/lib/pkgconfig"
pkg-config --modversion fuse3             # 3.2
```

The shim is a small DLL that dynamically loads the already-installed
`winfsp-x64.dll`, so only the headers and wrapper need to be built locally.

## 3. Build

From a **Cygwin shell**:

```sh
cd /cygdrive/x/AI\ Projects/OpenCode\ Evil/sshfs-win-modern
make check          # optional: verify FUSE3 + toolchain
make                # extracts vendored sshfs, patches, meson, ninja, bundles DLLs
```

Output layout:

```
.build/x64/root/bin/sshfs.exe        # upstream sshfs 3.7.7 (patched, always named sshfs.exe)
.build/x64/root/bin/sshfs-win.exe    # Windows launcher (cmd/svc modes)
.build/x64/root/bin/*.dll            # Cygwin runtime DLLs + cygfuse-3.2.dll FUSE3 shim
.build/x64/src/sshfs/                # patched upstream source + meson build dir
```

Sanity-check the binaries:

```sh
.build/x64/root/bin/sshfs.exe --version
# SSHFS version 3.7.7
# FUSE library version 3.2
```

## 4. Manual build (without the Makefile)

Useful when debugging a patch:

```sh
# from the project root, in a Cygwin shell
PATCHDIR=$(pwd)/patches
mkdir -p scratch && cd scratch
tar -xf ../vendor/sshfs-3.7.7.tar.xz
cd sshfs-3.7.7
for p in "$PATCHDIR"/*.patch; do
    patch --binary -p1 < "$p"
done
meson setup bld .
ninja -C bld
```

## 5. MSI installer (optional)

Install WiX v3, set `WIX`, then from Cygwin. WiX can also be used without an
admin install: download `wix314-binaries.zip` from the
[WiX v3 releases](https://github.com/wixtoolset/wix3/releases/latest), extract
it, and set `WIX` to a directory whose `bin/` contains `candle.exe`,
`light.exe` and `heat.exe`.

```sh
export WIX='/cygdrive/c/Program Files (x86)/WiX Toolset v3.14'
make msi
make dist      # copies the MSI into .build/x64/dist
```

The included `sshfs-win.wxs` is the upstream SSHFS-Win installer definition. It is
unmodified except for being fed the 3.7.7 version strings by the Makefile.
No authenticode signing is performed; unsigned MSIs are fine for local use but
Explorer/SmartScreen will warn. Sign it with your own certificate if distributing.

## 6. Install and test

Copy `.build/x64/root/` to `C:\Program Files\SSHFS-Win` (or add it to `PATH`), then:

```powershell
net use X: \\sshfs\REMUSER@HOST
dir X:\
net use X: /delete
```

The full UNC syntax is unchanged from SSHFS-Win:

```
\\sshfs\[LOCUSER=]REMUSER@HOST[!PORT][\PATH]
\\sshfs.r\...     # remote root instead of home
\\sshfs.k\...     # key auth (home)
\\sshfs.kr\...    # key auth (root)
```

`tests/smoke.ps1` automates mount/list/unmount:

```powershell
.\tests\smoke.ps1 -HostName myhost -RemoteUser me -Drive X:
```

## 7. What was changed vs. upstream and vs. sshfs-win

| Item | Status |
|---|---|
| Upstream sshfs version | **3.7.7** (vs. sshfs-win's pinned 3.7.1 submodule / 2021 release) |
| FUSE API | WinFsp **FUSE3** layer (`fuse3.pc`, `FUSE_USE_VERSION=31`) |
| `00-password-stdout.patch` | Rebased: adds `-o password_stdout`, needed by the launcher's Credential Manager handshake |
| `10-mountpoint.patch` | Rebased: accepts empty/`*` mountpoints (UNC-only and Mount Manager mounts) |
| `20-mountmgr.patch` | Rebased: accepts `\\.\X:` mountpoints |
| `30-stdiomode.patch` from sshfs-win | **Dropped** — `OPENSSH_STDIO_MODE=nonsock` is already upstream since 2024 |
| Launcher | Three fixes: (1) `-o rellinks` → `-otransform_symlinks -ono_contain_symlinks`; (2) it resolves `sshfs.exe` and `ssh.exe` relative to its own binary via `GetModuleFileNameA` + `/cygdrive/<letter>` conversion instead of hardcoding `/usr/bin/...`; (3) spaces in that path are double-backslash-escaped so WinFsp's option parser leaves the single escape sshfs's tokenizer needs (matters for `C:\Program Files\...`). |
| Installer | Reused verbatim from sshfs-win (GPLv2) |

All three patches were verified with `git apply --check` in sequence against a
clean `sshfs-3.7.7` source tree. An API audit also confirmed every `fuse_*`
symbol sshfs uses is present in WinFsp's FUSE3 headers; the only three missing
ones (`fuse_lowlevel.h`, `fuse_lowlevel_version`, `fuse_session_fd`) are compiled
out by upstream's `__CYGWIN__` / `__APPLE__` guards.

## 8. Known limitations

These come from the WinFsp FUSE emulation, not from sshfs itself:

* Hard links (`link`), `lock`, `bmap`, `poll`, `write_buf`/`read_buf`, `flock`, and
  `fallocate` callbacks are marked unsupported by WinFsp's FUSE layer.
* Extended attributes are only partially mapped onto Windows ADS/reparse points.
* POSIX special files (FIFOs, devices, sockets) are exposed via reparse points;
  plain Windows applications mostly see them as opaque entries.
* `sshfs --version` reports FUSE library version `3.2`, not the Linux libfuse version.
* Password auth requires the `password_stdout` patch; key auth relies on
  `%USERPROFILE%\.ssh\id_rsa` or an `ssh config` alias as documented by SSHFS-Win.
* Mount-Manager/UNC-only mounts pass `*` as the mountpoint. Cygwin expands `*` in
  argv before `main()`, so the launcher normalizes a non-`X:` mountpoint back
  to `*` and sets `CYGWIN=noglob` for the child. For the launcher's *own* argv,
  set `CYGWIN=noglob` in the WinFsp service environment if you rely on that
  mount form; ordinary `net use X:` mappings are unaffected.
* **Security trade-off in the launcher defaults**: `-ono_contain_symlinks`
  restores the old (3.7.1-era) symlink behavior, which also opts out of the
  CVE-2026-47187 containment protection added in 3.7.6. If you don't need
  absolute or `..`-containing symlink targets from the server, remove that
  option (and optionally `-otransform_symlinks`) from `sshfs-win.c` to keep the
  safer upstream default.

## 9. Upgrading the vendored sshfs

1. Download the new `sshfs-X.Y.Z.tar.xz` into `vendor/`.
2. Update `SSHFS_VERSION` in the Makefile.
3. Re-apply the three patches; if they no longer apply, regenerate them against
   the new source (`git diff --no-index` works well) and keep the changes minimal.
4. Check upstream `ChangeLog.rst`: do **not** re-add fixes that were merged
   upstream (as happened with `30-stdiomode.patch`).

## License

Upstream sshfs and sshfs-win.c are GPLv2+; WinFsp is GPLv3 with a commercial
license option. See `License.txt` and the license headers in each source file.
