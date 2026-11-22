# SSHFS-Win (updated)

> SSHFS 3.7.7 for Windows, built on WinFsp's FUSE3 layer.

> [!IMPORTANT]
> Updated project: upstream sshfs 3.7.7 on WinFsp FUSE3. The official SSHFS-Win
> installer is based on sshfs 3.7.1. Build a current MSI with `make msi`.

The official [SSHFS-Win](https://github.com/winfsp/sshfs-win) port is frozen at
upstream sshfs 3.7.1. This repository refreshes it to current upstream while
keeping the familiar experience: `net use`, drive letters, UNC prefixes,
Credential Manager authentication, and an MSI installer.

---

## Highlights

| | |
|---|---|
| Upstream | [libfuse/sshfs](https://github.com/libfuse/sshfs) 3.7.7 |
| FUSE API | WinFsp FUSE3, reports 3.2 (`FUSE_USE_VERSION=31`) |
| POSIX layer | Cygwin (pthreads, GLib, OpenSSH) |
| Patches | Three small Windows patches, all applying cleanly in sequence |
| Installer | WiX v3 MSI, built with `make msi` |

## Quick start

From a Cygwin shell:

```sh
sh tools/install-cygfuse.sh
make
```

If WinFsp was installed via winget and has no `opt/cygfuse`, build the shim locally:

```sh
sh tools/build-local-cygfuse.sh
export PATH="/usr/local/fuse3win/bin:$PATH"
export PKG_CONFIG_PATH="/usr/local/fuse3win/lib/pkgconfig"
make
```

Then, from PowerShell:

```powershell
net use X: \\sshfs\user@server.example.com
dir X:\
net use X: /delete
```

See [BUILDING.md](BUILDING.md) for prerequisites, manual builds, MSI packaging,
troubleshooting, and limitations.

## Architecture

```
net use / Explorer
        |
        v
WinFsp launcher service
        |
        v
sshfs-win.exe  --->  sshfs.exe  --->  SFTP over SSH
        |                 |
        |                 +-- Cygwin OpenSSH
        v
WinFsp FUSE3 emulation (cygfuse-3.2.dll)
        |
        v
WinFsp kernel driver
```

Upstream `sshfs.c` compiles almost unchanged. The three patches only cover
Windows-specific mountpoint syntax and the password handshake. SFTP, caching,
symlink handling, and reconnect logic remain upstream code.

## Repository layout

| Path | Purpose |
|---|---|
| `Makefile` | Cygwin build driver |
| `BUILDING.md` | Full build and install guide |
| `patches/` | Three Windows patches, rebased for 3.7.7 |
| `vendor/` | Vendored upstream source tarball |
| `sshfs-win.c` | Windows launcher (`cmd` and `svc` modes) |
| `sshfs-win.wxs` | WiX v3 installer definition |
| `etc/` | Bundled Cygwin configuration |
| `art/` | WiX UI bitmaps |
| `tools/` | FUSE setup helpers |
| `tests/` | Mount smoke test |

## UNC syntax

| Prefix | Remote location |
|---|---|
| `\\sshfs\REMUSER@HOST[\PATH]` | Remote user's home directory |
| `\\sshfs.r\...` | Remote root directory |
| `\\sshfs.k\...` | Key authentication, home directory |
| `\\sshfs.kr\...` | Key authentication, root directory |

## Limitations

* No updated x86 installer. Cygwin has dropped 32-bit support, so only the x64 MSI is published.
* No native MSVC build. Cygwin is required for the POSIX runtime.
* No authenticode signing. Sign the MSI yourself before distributing it.
* WinFsp's FUSE layer does not support every POSIX filesystem operation.
* The launcher's default symlink options preserve legacy behavior and therefore
  opt out of the symlink containment added in sshfs 3.7.6. See `BUILDING.md`.

## Credits

* Miklos Szeredi and the libfuse/sshfs contributors — upstream SSHFS.
* Bill Zissimopoulos and the WinFsp project — WinFsp and the original SSHFS-Win port.

## License

GPLv2+ for sshfs and the launcher. See `License.txt` and individual source headers.
WinFsp is GPLv3 with a commercial license option.
