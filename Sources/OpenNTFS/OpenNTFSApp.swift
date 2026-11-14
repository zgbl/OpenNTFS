import SwiftUI

@main
struct OpenNTFSApp: App {
    @StateObject private var monitor = DiskMonitor()

    init() {
        CLI.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
        } label: {
            Image(systemName: monitor.volumes.contains { $0.state == .readWrite }
                  ? "externaldrive.fill.badge.checkmark" : "externaldrive")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
    }
}

/// 命令行模式，复用与图形界面完全相同的 DiskMonitor 逻辑：
///   OpenNTFS --list
///   OpenNTFS --rw | --ro | --unmount | --eject  <diskXsY>
@MainActor
enum CLI {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, cmd.hasPrefix("--"), cmd != "--" else { return }
        if cmd.hasPrefix("-NS") || cmd.hasPrefix("-Apple") { return }

        let monitor = DiskMonitor()
        spin(1.5)  // 等待 DiskArbitration 回调把现有磁盘报上来

        func find() -> NTFSVolume? {
            guard args.count >= 2 else { fail("缺少设备参数，例如 disk4s1") }
            guard let v = monitor.volumes.first(where: { $0.bsdName == args[1] }) else {
                fail("未找到 NTFS 分区 \(args[1])")
            }
            return v
        }

        switch cmd {
        case "--list":
            if monitor.volumes.isEmpty { print("未检测到 NTFS 磁盘") }
            for v in monitor.volumes {
                print("\(v.bsdName)\t\(v.displayName)\t\(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))\t\(v.driverLabel)\t\(v.mountPoint ?? "-")")
            }
            exit(0)
        case "--rw": run(monitor) { await monitor.mountReadWrite(find()!) }
        case "--ro": run(monitor) { await monitor.switchToReadOnly(find()!) }
        case "--unmount": run(monitor) { await monitor.unmount(find()!) }
        case "--eject": run(monitor) { await monitor.eject(find()!) }
        default: fail("未知参数 \(cmd)。可用：--list, --rw, --ro, --unmount, --eject")
        }
    }

    private static func run(_ monitor: DiskMonitor, _ op: @escaping () async -> Void) -> Never {
        var done = false
        Task { @MainActor in await op(); done = true }
        while !done { spin(0.1) }
        monitor.refresh()
        if let e = monitor.lastError { fail(e) }
        if let m = monitor.lastMessage { print(m) }
        for v in monitor.volumes { print("\(v.bsdName)\t\(v.driverLabel)\t\(v.mountPoint ?? "-")") }
        exit(0)
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data(("错误：" + msg + "\n").utf8))
        exit(1)
    }
}
