# OpenNTFS Design Document

| Item | Detail |
|---|---|
| Status | Implemented, v1.0 |
| Target platform | macOS 14+ (FSKit mode needs 15.4+). Verified on macOS 27.2.1 / Apple Silicon |
| Runtime dependency | macFUSE 5.x |
| Repository | https://github.com/zgbl/OpenNTFS |

---

## 1. Background

macOS's built-in NTFS driver only reads. Windows-formatted external drives, which are very common, can't be written on a Mac, so users have to rely on commercial drivers such as Paragon NTFS for Mac or Tuxera NTFS. Those products are paid, closed-source, and on Apple Silicon generally need a kernel extension, which in turn means booting into Recovery and lowering the Mac's security level.

Two open-source building blocks exist: ntfs-3g (a mature NTFS read/write implementation) and macFUSE (a user-space file system framework). macFUSE 5 also adds an **FSKit backend**, built on Apple's user-space file system framework, which can mount file systems without a kernel extension. What's missing is the glue on top: a product that's reliable, easy to use, and works within the modern macOS security model.

## 2. Goals and non-goals

### 2.1 Goals

| # | Goal |
|---|---|
| G1 | Read and write NTFS external drives, with day-to-day behavior (Finder copy, rename, xattrs) matching a native volume |
| G2 | **No kernel extension and no lowered system security** (on macOS 15.4+) |
| G3 | Simple to use: detect drives when plugged in, switch read/write with one click, eject safely |
| G4 | Safety first: any failure falls back to read-only automatically, and data is never written to a volume in an unknown state |
| G5 | Least privilege: as little runs as root as possible, every privileged argument is strictly validated, and no system permission changes are left behind |
| G6 | Replaces Paragon NTFS for Mac |

### 2.2 Non-goals

- Implementing NTFS read/write logic ourselves. ntfs-3g is reused, and its read/write code isn't modified.
- Formatting, repairing (chkdsk) or partitioning NTFS volumes.
- Distribution through the Mac App Store. The app needs root privileges and Full Disk Access, which App Store sandboxing doesn't allow.
- Read/write for other file systems, such as ext4 or APFS.

## 3. Overall architecture

```
┌──────────────────────────────── User session (uid = current user) ───────────────────────────────┐
│                                                                                                    │
│  OpenNTFS.app (menu bar app, holds "Full Disk Access")                                             │
│   ├─ Views          menu bar panel / settings window                                               │
│   ├─ DiskMonitor    DiskArbitration events, state machine, mount/unmount/eject orchestration      │
│   ├─ NTFS3G         bundled ntfs-3g path, mount options, process scan (state detection)           │
│   └─ Privileged     sudo -A / sudo -n → ntfs-helper.sh                                             │
│            │                                                                                       │
│            ▼ sudo (started directly by the app, so privacy checks still attribute it to OpenNTFS) │
│   ┌─ ntfs-helper.sh (root, very short-lived) ──────────────────────────────────┐                  │
│   │  validate args → unmount system read-only mount → open partition (fd 3)   │                  │
│   │  → setgid/setuid drops to current user → exec ntfs-3g /dev/fd/3            │                  │
│   └───────────────────────────────────────────────────────────────────────────┘                   │
│            │                                                                                       │
│            ▼                                                                                       │
│  ntfs-3g (patched build, runs as current user, long-lived daemon)                                  │
│            │ libfuse                                                                               │
└────────────┼───────────────────────────────────────────────────────────────────────────────────────┘
             ▼
     macFUSE ──► FSKit (fskitd) ──► /Volumes/<volume name>  ◄── Finder / apps
```

**Core idea:** root only does the one thing that genuinely needs privileges, which is opening the raw device, and drops privileges straight away. The long-running file system daemon (ntfs-3g) runs as the current user. That is also a hard requirement of macFUSE's FSKit backend (see §5.1).

## 4. Components

### 4.1 DiskMonitor (`Sources/OpenNTFS/DiskMonitor.swift`)

- **Discovery:** registers DiskArbitration appeared, disappeared and description-changed callbacks, and treats partitions whose `VolumeKind` contains `ntfs` as NTFS volumes. These events drive the state updates, with a 5-second timer as a fallback.
- **State model:** `unmounted` / `readOnly` (system driver) / `readWrite` (ntfs-3g).
- **State detection:** the mount table (`getmntinfo`) and the ntfs-3g process scan are combined. Under FSKit, the mount source is a virtual disk that macFUSE creates, so it can't be matched to the real partition directly (see §4.2).
- **Operations:** read/write mount, read-only mount, switch to read-only, unmount, eject. They are serialized per volume, and **any failed read/write mount falls back to the system read-only mount**.
- **Auto-mount:** optionally switches an external drive to read/write automatically when it's plugged in.

### 4.2 NTFS3G (`Sources/OpenNTFS/NTFS3G.swift`)

- Locates the bundled ntfs-3g (`Contents/Helpers/ntfs-3g`).
- Builds the FSKit mount options (see §5.4).
- **Process scan:** enumerates ntfs-3g processes with `proc_listallpids` + `KERN_PROCARGS2` to get each process's `<device> <mount point>`. When the device is `/dev/fd/N`, `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` resolves it to the real `/dev/diskXsY`.

### 4.3 Privileged (`Sources/OpenNTFS/Shell.swift`)

- Default: `sudo -A <helper>`. The password prompt comes from `Resources/askpass.sh`.
- Passwordless mode (optional): the helper is copied to `/Library/PrivilegedHelperTools` (owned by root), and `/etc/sudoers.d/openntfs` lets **only the current user** run **that one file** without a password. It is then called with `sudo -n`.

### 4.4 ntfs-helper.sh (`Resources/ntfs-helper.sh`)

The only code that runs as root. Commands:

| Command | Purpose |
|---|---|
| `fdmount <dev> <uid> <gid> <ntfs-3g> <mount point> <volume name>` | FSKit read/write mount (default path) |
| `mount <dev> <volume name> <uid> <gid> kext [ntfs-3g]` | Kernel-extension-mode read/write mount (macOS < 15.4) |
| `unmount <dev> <mount point>` | Unmount fallback |
| `ping` | Health check |

See §6 for what each command validates.

### 4.5 Patched ntfs-3g (`vendor/`)

- Based on ntfs-3g **2026.9.28**. `build-ntfs-3g.sh` downloads it, checks its SHA256, applies the patch and builds it.
- The patch (`openntfs-unprivileged-fskit.patch`) has two changes, both behind `#ifdef __APPLE__`:
  1. `src/ntfs-3g.c`: when not running as root, the device isn't treated as a Linux fuseblk device, so the "normal users can't mount block devices" refusal no longer triggers.
  2. `libntfs-3g/unix_io.c`: a device name of `/dev/fd/N` is handled with `dup(N)`, after checking the descriptor's access mode, instead of `open()`.
- **ntfs-3g's NTFS read/write logic is untouched, and behavior when running as root is unchanged.**

### 4.6 Packaging (`build.sh`)

```
OpenNTFS.app/Contents/
├── MacOS/OpenNTFS                 universal binary (arm64 + x86_64); FSKit is weak-linked
├── Helpers/ntfs-3g                patched ntfs-3g
├── Frameworks/libntfs-3g.91.dylib, libintl.8.dylib    install names rewritten to @executable_path
└── Resources/ntfs-helper.sh, askpass.sh
```

libfuse is provided by the system-wide macFUSE install and isn't bundled.

## 5. Key design decisions

Each decision below was confirmed by testing on macOS 27.2.1. Every alternative that was ruled out has evidence recorded.

### 5.1 ntfs-3g must run as the current user, not as root

| Approach | Result |
|---|---|
| root + `backend=fskit` | ❌ The mount hangs, and macFUSE pops up "please enable the file system extension" |
| Current user + `backend=fskit` | ✅ Mounts in a few seconds |

**Cause:** macFUSE's FSKit extension switch is stored per user (`pluginkit` election). root has its own, separate setting, which is off and can't be changed (`pluginkit` as root returns `Connection invalid`).

**Consequence:** stock ntfs-3g refuses to let a normal user mount a block device, so it has to be patched (§4.5, change 1).

### 5.2 Hand the device to the user process as a file descriptor, without changing `/dev` permissions

| Approach | Result |
|---|---|
| `chown` the `/dev/diskXsY` node to the user | ❌ macOS refuses (EPERM), even as root |
| User process opens `/dev/fd/N` | ❌ On macOS this re-checks the permissions of the underlying `/dev` node instead of duplicating the descriptor |
| **root opens the device → setuid drops privileges → exec ntfs-3g; ntfs-3g `dup()`s fd 3** | ✅ |

Benefits: `/dev` permissions are never changed, no grant persists, and the descriptor is closed automatically when ntfs-3g exits. The Perl that does the privilege drop has to set `$^F = 255` and explicitly clear `FD_CLOEXEC`. Otherwise fd 3 is closed at exec time.

### 5.3 Get privileges with `sudo -A`, not AppleScript

| Approach | Result |
|---|---|
| `osascript … with administrator privileges` | ❌ Goes through `authtrampoline`. The privacy check (`kTCCServiceSystemPolicyRemovableVolumes`) attributes the process to authtrampoline, so the Full Disk Access granted to OpenNTFS doesn't apply and opening the raw device is denied |
| **OpenNTFS runs `sudo -A` directly** | ✅ The "responsible app" is still OpenNTFS |

Prerequisite: the user has to grant OpenNTFS "Full Disk Access" once.

### 5.4 FSKit mount options

| Option | Reason |
|---|---|
| `backend=fskit` | Use FSKit, so no kernel extension is needed |
| `local` | Treated by the system as a local volume and shown in Finder's sidebar |
| `noalerts` | Stops macFUSE showing modal alerts that would interrupt automated flows |
| `streams_interface=openxattr` | **Required.** Allows macOS `com.apple.*` xattrs, stored as NTFS named data streams. Without it, Finder copies fail with error 100102 |
| `noappledouble` | No `._*` files are written to the volume |
| `windows_names` | Rejects file names Windows doesn't allow, keeping the volume compatible across platforms |
| ~~`auto_xattr`~~ | **Must not be used.** Only the kernel-extension backend implements it, and under FSKit it returns "not supported" |

### 5.5 State detection

Under FSKit, `f_mntfromname` holds macFUSE's virtual disk (such as `/dev/disk16s1`) or `macfuse://UUID`, not the real partition. The real partition is therefore identified from the ntfs-3g process's arguments, and from the path behind fd 3 when the device was passed as a descriptor. This also works across app restarts, with no extra state to persist.

### 5.6 Compatibility fallback

- FSKit is weak-linked (`-weak_framework FSKit`) and guarded with `#if canImport(FSKit)`, so the app launches on older systems and builds with older SDKs.
- Below macOS 15.4, the app switches to kernel-extension mode automatically. In that mode ntfs-3g runs as root, and on Apple Silicon the user has to lower security in Recovery.
- `FSClient.installedExtensions` doesn't list macFUSE's modules, so it's used as a hint only and never blocks a mount.

## 6. Security model

| Threat / concern | Mitigation |
|---|---|
| Code running as root | Only `ntfs-helper.sh` runs as root, only briefly, and it drops privileges before exec |
| Argument injection | Device names must match `^disk[0-9]+s[0-9]+$` and be existing block devices; uid/gid must be digits; mount points must be under `/Volumes/` with no `..`; the ntfs-3g path must end in `/ntfs-3g` |
| Using the helper to access a non-NTFS disk | `fdmount` uses `diskutil info` to confirm the partition is NTFS; other volumes, such as the system APFS volume, are refused |
| Privilege escalation through passwordless sudo | sudoers allows only one root-owned file; `fdmount` refuses uid 0 and requires uid to equal `SUDO_UID` |
| The installed helper going stale after an app update | Before each mount, compare the installed copy with the bundled one; reinstall if they differ (asks for the password once) |
| Leftover permissions | `/dev` permissions are never changed; the device descriptor closes when the process exits |
| Data safety | Hibernated or not-cleanly-unmounted volumes are refused by ntfs-3g (exit codes 14/15) and fall back to read-only; a mount that times out kills ntfs-3g and falls back to read-only; on eject, the app waits for ntfs-3g to flush its cache and exit |

## 7. Main flows

### 7.1 Read/write mount (FSKit, physical drive)

1. The user clicks "Enable read/write".
2. If the extension status is visible, the app checks it.
3. It picks a free mount point under `/Volumes/<volume name>`.
4. It runs `sudo -A ntfs-helper.sh fdmount …`, and the user enters their password.
5. The helper validates the arguments, unmounts the system read-only mount, opens the partition read/write, drops privileges, and execs ntfs-3g `/dev/fd/3`.
6. ntfs-3g forks into the background, and macFUSE/FSKit completes the mount.
7. The app polls the mount table for up to 15 seconds. On success, the UI shows "ntfs-3g · read/write". On timeout or failure, it kills ntfs-3g and falls back to the system read-only mount.

Disk images, whose `/dev` node already belongs to the user, skip the sudo step and run directly as the user.

### 7.2 Eject

1. Unmount every volume on the same physical disk that's mounted read/write, using `diskutil unmount` as the user.
2. Wait up to 10 seconds for ntfs-3g to exit, so its cache is written back to disk.
3. Run `diskutil eject <whole disk>`.

## 8. Testing

Command-line mode (`OpenNTFS --list | --rw | --ro | --unmount | --eject <diskXsY>`) runs exactly the same code as the GUI and is used for automated testing.

| Scenario | Environment | Result |
|---|---|---|
| Read-only → read/write → read-only → read/write | 512 MB NTFS disk image | ✅ |
| Create, rename, delete, append; Chinese names, names with spaces | Disk image | ✅ |
| Writing xattrs with Chinese values | Disk image | ✅ |
| 100 MB Finder copy, read back by the system read-only driver with matching SHA1 | Disk image | ✅ |
| Ejecting straight from read/write mode; data written just before the eject is preserved | Disk image | ✅ |
| **Physical drive read/write** (create, read back, xattrs, delete its own test file; the user's files untouched) | **Seagate 2 TB USB** | ✅ |
| Helper argument validation (root uid, impersonating another user, illegal paths, non-NTFS partition) | — | ✅ All refused |

Environment: macOS 27.2.1 (Apple Silicon), macFUSE 5.5.0.

## 9. Known limitations and risks

| Item | Notes |
|---|---|
| FSKit performance | I/O is somewhat slower than the kernel-extension backend (from the macFUSE release notes) |
| Sparse files | Not supported by the FSKit backend for now |
| `df` usage | Under FSKit, "used" is reported as 0, though available space is correct. It's a display issue only |
| Ad-hoc signing | Can be used locally. Distributing it to others needs a Developer ID signature and notarization |
| Dependency on macFUSE APIs | macFUSE's FSKit-related APIs are still evolving; future versions may need adjustments |
| Intel / older systems | Code paths exist and a universal build compiles, but they haven't been tested on real hardware |
| Patch maintenance | Upgrading ntfs-3g means re-checking that the two hunks still apply |

## 10. Future work

- Developer ID signing and notarization, plus a DMG installer.
- An SMAppService privileged daemon to replace sudoers-based passwordless mode, for finer-grained authorization.
- Proposing the two ntfs-3g patches upstream (tuxera/ntfs-3g) or to the Homebrew formula maintainers.
- `ntfsfix` / volume health checks and a guided Windows Fast Startup prompt.
- Automated regression tests based on disk images.
