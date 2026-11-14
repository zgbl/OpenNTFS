import AppKit
import DiskArbitration
import Foundation
import FSKit

enum MountState: Equatable {
    case unmounted
    case readOnly       // 系统自带驱动，只读
    case readWrite      // 已通过 ntfs-3g（或其他驱动）读写挂载
}

struct NTFSVolume: Identifiable, Equatable {
    var id: String { bsdName }
    let bsdName: String          // disk4s1
    let wholeDisk: String?       // disk4
    var name: String
    var size: Int64
    var isInternal: Bool
    var deviceModel: String?
    var busProtocol: String?
    // 来自挂载表
    var mountPoint: String?
    var fsType: String?
    var state: MountState = .unmounted

    var displayName: String { name.isEmpty ? "未命名 NTFS 磁盘" : name }

    var driverLabel: String {
        guard let fs = fsType?.lowercased() else { return "未挂载" }
        if fs == "ntfs" { return "系统驱动 · 只读" }
        if fs.contains("fuse") || fs.contains("fskit") { return "ntfs-3g · 读写" }
        if fs.contains("ufsd") { return "Paragon · " + (state == .readWrite ? "读写" : "只读") }
        return fs + (state == .readWrite ? " · 读写" : " · 只读")
    }
}

/// 一条挂载表记录（来自 getmntinfo）
struct MountEntry {
    let from: String
    let on: String
    let type: String
    let readOnly: Bool

    static func all() -> [MountEntry] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        return (0..<Int(n)).map { i in
            var s = buf[i]
            return MountEntry(
                from: cString(&s.f_mntfromname),
                on: cString(&s.f_mntonname),
                type: cString(&s.f_fstypename),
                readOnly: (s.f_flags & UInt32(MNT_RDONLY)) != 0)
        }
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}

@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var volumes: [NTFSVolume] = []
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published private(set) var deps = Dependencies.check()

    private var session: DASession?
    private var known: [String: NTFSVolume] = [:]     // 由 DiskArbitration 发现的 NTFS 分区
    private var autoMountedOnce: Set<String> = []

    var autoMountRW: Bool { UserDefaults.standard.bool(forKey: Prefs.autoMountKey) }
    var useFSKit: Bool { UserDefaults.standard.bool(forKey: Prefs.fskitKey) }

    init() {
        // macOS 15.4+ 默认用 FSKit（无需内核扩展、无需降低安全性）
        if #available(macOS 15.4, *) {
            UserDefaults.standard.register(defaults: [Prefs.fskitKey: true])
        }
        startDiskArbitration()
        // 兜底：定时刷新挂载状态（例如用户在终端里手动卸载）
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - DiskArbitration

    private func startDiskArbitration() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.diskAppeared(disk) }
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.diskDisappeared(disk) }
        }, ctx)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.diskAppeared(disk) }
        }, ctx)
    }

    private func diskAppeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }

        let kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        guard kind.contains("ntfs") else {
            if known.removeValue(forKey: bsd) != nil { refresh() }
            return
        }
        let isNew = known[bsd] == nil
        // 注意保持 wholeDisk 对象存活到读完名字为止，否则 DADiskGetBSDName 返回的指针会悬空
        var whole: String?
        if let wholeDisk = DADiskCopyWholeDisk(disk), let p = DADiskGetBSDName(wholeDisk) {
            whole = String(cString: p)
            withExtendedLifetime(wholeDisk) {}
        }

        known[bsd] = NTFSVolume(
            bsdName: bsd,
            wholeDisk: whole,
            name: desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? "",
            size: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
            isInternal: desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false,
            deviceModel: (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces),
            busProtocol: desc[kDADiskDescriptionDeviceProtocolKey as String] as? String)
        refresh()

        if isNew, autoMountRW, !(known[bsd]?.isInternal ?? true) {
            // 等系统先完成只读挂载，再切换成读写
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let v = self.volumes.first(where: { $0.bsdName == bsd }),
                      v.state != .readWrite, !self.autoMountedOnce.contains(bsd) else { return }
                self.autoMountedOnce.insert(bsd)
                Task { await self.mountReadWrite(v) }
            }
        }
    }

    private func diskDisappeared(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        known.removeValue(forKey: bsd)
        autoMountedOnce.remove(bsd)
        refresh()
    }

    // MARK: - 状态

    func refresh() {
        let mounts = MountEntry.all()
        let procs = NTFS3G.running()
        var list: [NTFSVolume] = []
        for var v in known.values {
            let dev = "/dev/\(v.bsdName)"
            if let p = procs.first(where: { $0.device == dev }),
               let m = mounts.first(where: { $0.on == p.mountPoint }) {
                // FSKit：挂载来源显示为 macFUSE 虚拟的磁盘，按 ntfs-3g 进程参数对应回来
                v.mountPoint = m.on
                v.fsType = m.type
                v.state = m.readOnly ? .readOnly : .readWrite
            } else if let m = mounts.first(where: { $0.from == dev }) {
                v.mountPoint = m.on
                v.fsType = m.type
                v.state = m.readOnly ? .readOnly : .readWrite
            } else {
                v.mountPoint = nil
                v.fsType = nil
                v.state = .unmounted
            }
            list.append(v)
        }
        list.sort { ($0.isInternal ? 1 : 0, $0.bsdName) < ($1.isInternal ? 1 : 0, $1.bsdName) }
        if list != volumes { volumes = list }
    }

    func recheckDependencies() { deps = Dependencies.check() }

    // MARK: - 操作

    func mountReadWrite(_ v: NTFSVolume) async {
        recheckDependencies()
        guard deps.ready else {
            lastError = "缺少依赖：" + deps.missingDescription + "。请在「设置」中查看安装方法。"
            return
        }
        await perform(v) {
            let useFSKit = self.useFSKit
            if useFSKit {
                guard #available(macOS 15.4, *) else {
                    self.lastError = "FSKit 读写挂载需要 macOS 15.4 或更新版本。"
                    return
                }
                // 注意：FSClient.installedExtensions 在 macOS 27 上不会列出 macFUSE 的模块（实测只返回系统自带的），
                // 所以「查不到」不代表不可用，只在系统明确报告「已禁用」时才拦截；其余情况交给挂载超时兜底。
                if let extensions = try? await FSClient.shared.installedExtensions,
                   let fuse = extensions.first(where: { $0.bundleIdentifier.hasPrefix("io.macfuse.app.fsmodule") }),
                   !fuse.isEnabled {
                    self.lastError = "macFUSE 的文件系统扩展已被禁用。请在「系统设置 → 通用 → 登录项与扩展 → 按类别 → 文件系统扩展」启用后重试。"
                    return
                }
            }
            if useFSKit {
                await self.mountWithFSKit(v)
                return
            }
            let r = await Privileged.helper([
                "mount", v.bsdName, v.name, String(getuid()), String(getgid()), "kext",
            ])
            if r.ok {
                self.lastMessage = "「\(v.displayName)」已以读写模式挂载"
            } else {
                self.lastError = Self.explain(r)
            }
        }
    }

    /// FSKit 读写挂载：macFUSE 的 FSKit 后端只在 ntfs-3g 以当前用户身份运行时可用（以 root 运行会卡住），
    /// 所以只让 root 做两件小事（卸载系统只读挂载、把设备文件授权给当前用户），挂载本身以当前用户执行。
    private func mountWithFSKit(_ v: NTFSVolume) async {
        guard let ntfs3g = NTFS3G.bundledPath else {
            lastError = "未找到内置的 ntfs-3g，请重新构建 OpenNTFS（./build.sh）。"
            return
        }
        let dev = "/dev/\(v.bsdName)"

        // 1. 卸载系统只读挂载（普通用户即可）
        if let mp = v.mountPoint {
            let r = await Shell.run("/usr/sbin/diskutil", ["unmount", dev])
            if !r.ok {
                lastError = "无法卸载「\(v.displayName)」（\(mp)），可能有程序正在使用该磁盘。"
                return
            }
        }
        // 2/3. 以当前用户运行 ntfs-3g
        let mp = NTFS3G.pickMountPoint(for: v.name)
        let r: ShellResult
        if access(dev, R_OK | W_OK) == 0 {
            // 设备文件本来就归当前用户（如磁盘镜像）：直接运行，无需密码
            r = await Shell.run(ntfs3g, [dev, mp] + NTFS3G.fskitOptions(volumeName: v.name))
        } else {
            // 实体硬盘：macOS 不允许改设备权限，由助手以 root 打开设备后降权为当前用户运行 ntfs-3g（需要一次授权）
            r = await Privileged.helper([
                "fdmount", v.bsdName, String(getuid()), String(getgid()), ntfs3g, mp, v.name,
            ])
        }
        if !r.ok {
            lastError = Self.explain(r)
            await restoreReadOnly(dev)
            return
        }
        // 4. ntfs-3g 先 fork 再挂载，返回 0 不代表成功：轮询挂载表确认
        for _ in 0..<60 {
            if MountEntry.all().contains(where: { $0.on == mp }) {
                lastMessage = "「\(v.displayName)」已以读写模式挂载"
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        for p in NTFS3G.running() where p.device == dev { kill(p.pid, SIGKILL) }
        lastError = "读写挂载超时（15 秒）。请确认 macFUSE 的文件系统扩展已启用后重试。已恢复为只读挂载。"
        await restoreReadOnly(dev)
    }

    private func restoreReadOnly(_ dev: String) async {
        if !MountEntry.all().contains(where: { $0.from == dev }) {
            _ = await Shell.run("/usr/sbin/diskutil", ["mount", dev])
        }
    }

    func mountReadOnly(_ v: NTFSVolume) async {
        await perform(v) {
            let r = await Shell.run("/usr/sbin/diskutil", ["mount", "/dev/\(v.bsdName)"])
            if !r.ok { self.lastError = "只读挂载失败：" + (r.stderr.isEmpty ? r.stdout : r.stderr) }
        }
    }

    /// 读写 → 只读：卸载 ntfs-3g 后交还给系统驱动
    func switchToReadOnly(_ v: NTFSVolume) async {
        await unmount(v)
        if lastError == nil { await mountReadOnly(v) }
    }

    func unmount(_ v: NTFSVolume) async {
        guard let mp = v.mountPoint else { return }
        await perform(v) {
            // 系统只读挂载普通用户就能卸载；ntfs-3g 挂载由 root 创建，需走助手
            if v.fsType?.lowercased() == "ntfs" {
                let r = await Shell.run("/usr/sbin/diskutil", ["unmount", "/dev/\(v.bsdName)"])
                if !r.ok { self.lastError = "卸载失败：" + (r.stderr.isEmpty ? r.stdout : r.stderr) }
                return
            }
            let quick = await Shell.run("/usr/sbin/diskutil", ["unmount", mp])
            if quick.ok {
                // 等 ntfs-3g 把缓存写回磁盘并退出，之后才能安全推出/拔出
                let dev = "/dev/\(v.bsdName)"
                for _ in 0..<40 where NTFS3G.running().contains(where: { $0.device == dev }) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return
            }
            let r = await Privileged.helper(["unmount", v.bsdName, mp])
            if !r.ok { self.lastError = Self.explain(r) }
        }
    }

    func eject(_ v: NTFSVolume) async {
        // 先卸载同一物理磁盘上所有由我们（root）挂载的分区，再整体推出
        for other in volumes where other.wholeDisk == v.wholeDisk && other.state == .readWrite {
            await unmount(other)
            if lastError != nil { return }
        }
        guard let whole = v.wholeDisk else { return }
        await perform(v) {
            let r = await Shell.run("/usr/sbin/diskutil", ["eject", whole])
            if r.ok {
                self.lastMessage = "「\(v.displayName)」已推出，可以安全拔出"
            } else {
                self.lastError = "推出失败：" + (r.stderr.isEmpty ? r.stdout : r.stderr)
            }
        }
    }

    func openInFinder(_ v: NTFSVolume) {
        guard let mp = v.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }

    private func perform(_ v: NTFSVolume, _ body: @escaping () async -> Void) async {
        guard !busy.contains(v.bsdName) else { return }
        busy.insert(v.bsdName)
        lastError = nil
        lastMessage = nil
        await body()
        busy.remove(v.bsdName)
        refresh()
    }

    private static func explain(_ r: ShellResult) -> String {
        let detail = (r.stderr.isEmpty ? r.stdout : r.stderr)
        switch r.status {
        case -128: return "已取消授权"
        case 3: return "未找到 ntfs-3g。请在终端运行：brew install gromgit/fuse/ntfs-3g-mac"
        case 4: return "未找到 macFUSE。请在终端运行：brew install --cask macfuse"
        case 5:
            return "macFUSE (local) 在挂载进程中不可用。请在「系统设置 → 通用 → 登录项与扩展 → 按类别 → 文件系统扩展」确认开关后重试。\n\n详细信息：\(detail)"
        case 14:
            return "该磁盘上的 Windows 处于休眠/快速启动状态，为防止数据损坏无法读写挂载。请回到 Windows 中关闭「快速启动」并完全关机（或按住 Shift 点关机）后再试。已恢复为只读挂载。"
        case 15:
            return "该磁盘上次未被安全移除（文件系统不干净）。请在 Windows 中运行 chkdsk /f 修复后再试。已恢复为只读挂载。"
        case 16: return detail
        default:
            if detail.localizedCaseInsensitiveContains("fuse") && detail.localizedCaseInsensitiveContains("load") {
                return "macFUSE 内核扩展未加载。Apple 芯片需要在「系统设置 → 隐私与安全性」中允许 macFUSE 的系统扩展（首次需进入恢复模式开启「降低安全性」），或在本应用设置中改用 FSKit 后端。\n\n详细信息：\(detail)"
            }
            return "操作失败（代码 \(r.status)）：\(detail)"
        }
    }
}

// MARK: - 依赖检测

struct Dependencies: Equatable {
    var macFUSE: Bool
    var ntfs3gPath: String?
    var ready: Bool { macFUSE && ntfs3gPath != nil }

    var missingDescription: String {
        var m: [String] = []
        if !macFUSE { m.append("macFUSE") }
        if ntfs3gPath == nil { m.append("ntfs-3g") }
        return m.joined(separator: "、")
    }

    static var installCommand: String {
        NTFS3G.bundledPath != nil
            ? "brew install --cask macfuse"
            : "brew install --cask macfuse && brew install gromgit/fuse/ntfs-3g-mac"
    }

    static func check() -> Dependencies {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/ntfs-3g", "/opt/homebrew/sbin/ntfs-3g",
                          "/usr/local/bin/ntfs-3g", "/usr/local/sbin/ntfs-3g"]
        return Dependencies(
            macFUSE: fm.fileExists(atPath: "/Library/Filesystems/macfuse.fs"),
            ntfs3gPath: NTFS3G.bundledPath ?? candidates.first { fm.isExecutableFile(atPath: $0) })
    }
}

enum Prefs {
    static let autoMountKey = "autoMountRW"
    static let fskitKey = "useFSKitBackend"
}
