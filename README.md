# OpenNTFS

A free, open-source replacement for Paragon NTFS: a macOS menu bar app that gives NTFS drives **read and write** access.

On macOS 15.4 and later it uses **macFUSE's FSKit backend**. That means no kernel extension, and no need to boot into Recovery and lower the Mac's security level.

## Features

- Uses DiskArbitration to detect NTFS drives as soon as they're plugged in. The menu bar shows each drive's capacity, model and current mode (read-only or read/write).
- Enable read/write with one click, switch back to read-only, unmount, open in Finder, or eject safely.
- Ships with a patched ntfs-3g, so the only thing you need to install is macFUSE.
- Optional: mount external drives read/write automatically when they're plugged in. Optional: stop asking for a password. Launch at login.
- Clear error messages when Windows is hibernated, Fast Startup is on, or the volume wasn't shut down cleanly. In each case the drive falls back to read-only, so nothing gets damaged.
- Command-line mode that runs the same code as the app: `OpenNTFS --list | --rw | --ro | --unmount | --eject <diskXsY>`

## Install

```sh
brew install --cask macfuse            # The only runtime dependency
brew install autoconf automake libtool pkgconf gettext   # Build tools
./build.sh                             # Builds the patched ntfs-3g and OpenNTFS.app
cp -R build/OpenNTFS.app /Applications/
```

macFUSE's file system extension must be turned on, which it normally is by default. If you can't find it under "System Settings → General → Login Items & Extensions → Extensions → By Category → File System Extensions", run:

```sh
pluginkit -e use -i io.macfuse.app.fsmodule.macfuse
pluginkit -e use -i io.macfuse.app.fsmodule.macfuse-local
```

## How it works (FSKit mode)

These rules were established by testing on macOS 27:

| Approach | Result |
|---|---|
| ntfs-3g running as **root** + FSKit | ❌ The mount hangs, and macFUSE pops up "please enable the file system extension". The extension switch is stored per user, and root's switch is off and can't be turned on. |
| ntfs-3g running as **the current user** + FSKit | ✅ Works |
| Changing a physical drive's `/dev` permissions with `chown` | ❌ macOS refuses (EPERM), even as root |
| Opening a physical drive's `/dev` node from a process started via AppleScript `with administrator privileges` | ❌ The privacy check attributes the process to `authtrampoline`, so the app's "Full Disk Access" doesn't apply |
| On macOS, `open("/dev/fd/N")` | Re-checks the permissions of the underlying `/dev` node instead of duplicating the descriptor |

That leads to this approach:

1. **OpenNTFS runs `sudo -A` itself** (the password prompt comes from `askpass.sh`), so the "responsible app" for the privacy check is still OpenNTFS.
2. **`ntfs-helper.sh fdmount`**: as root, it unmounts the system's read-only mount, opens the partition read/write as fd 3, drops completely to the current user (setgid/setuid), and then execs ntfs-3g with `/dev/fd/3`. The `/dev` permissions are never changed and no grant is left behind. It mounts NTFS partitions only, and over sudo it only mounts for the calling user.
3. **The patched ntfs-3g** (`vendor/openntfs-unprivileged-fskit.patch`, active on macOS only):
   - When running as a normal user, it no longer treats the device as a Linux fuseblk device, so the "normal users can't mount block devices" refusal no longer triggers.
   - For `/dev/fd/N` it calls `dup(N)` instead of `open()`, after checking that the descriptor's access mode matches.
   - Behavior when running as root is unchanged, and the NTFS read/write code itself isn't touched.
4. Mount options: `backend=fskit,local,noalerts,noappledouble,windows_names,streams_interface=openxattr`
   - `streams_interface=openxattr` allows macOS `com.apple.*` xattrs. **Without it, Finder copies fail with error 100102.**
   - Don't use `auto_xattr`: only the kernel-extension backend implements it, and under FSKit it returns "not supported".
5. Under FSKit the mount source is a virtual disk that macFUSE creates. OpenNTFS reads ntfs-3g's process arguments and the path behind fd 3 (`proc_pidfdinfo`) to work out which partition is mounted where.

Disk images, whose `/dev` node already belongs to the user, mount directly as the user without a password.

**Requirement: grant OpenNTFS "Full Disk Access"** in "System Settings → Privacy & Security → Full Disk Access". Otherwise even root can't open the external drive.

## Code layout

- `Sources/OpenNTFS/DiskMonitor.swift`: disk detection, the mount table, mount/unmount/eject
- `Sources/OpenNTFS/NTFS3G.swift`: locating the bundled ntfs-3g, FSKit mount options, scanning ntfs-3g processes
- `Sources/OpenNTFS/Shell.swift`: running processes and getting privileges (osascript password prompt, or `sudo -n`)
- `Sources/OpenNTFS/Views.swift`: the menu bar panel and the settings window
- `Resources/ntfs-helper.sh`: the only code that runs as root (`fdmount` / `unmount` / the kext-mode `mount`). It strictly checks every argument.
- `Resources/askpass.sh`: the password prompt for `sudo -A`
- `vendor/build-ntfs-3g.sh`: downloads ntfs-3g 2026.9.28, checks its SHA256, applies the patch and compiles it

## Tested

Tested on macOS 27.2.1, Apple Silicon, with macFUSE 5.5.0:

- **A real 2 TB Seagate USB drive**: switching to read/write, writing, reading back, xattrs. Only a test file it created itself was written and then deleted; the drive's existing files were never touched.
- A 512 MB NTFS disk image:
  - Read-only → read/write → read-only → read/write
  - Create, rename, delete and append, with Chinese file names and directory names containing spaces
  - A 100 MB Finder copy, read back by macOS's own read-only driver with a matching SHA1
  - Ejecting straight from read/write mode. Data written just before the eject is preserved.

## Notes

- Always click "Eject" before unplugging the drive. Otherwise the NTFS file system can be damaged.
- If Windows has "Fast Startup" turned on, the drive stays hibernated and can't be written. Turn it off in Windows, or hold Shift while clicking Shut Down.
- The bundled ntfs-3g is arm64 only for now. Intel Macs need to build it themselves.
- FSKit limitations (from the macFUSE release notes): sparse files aren't supported, and I/O performance is somewhat lower than the kernel-extension backend.
