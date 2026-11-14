import Darwin
import Foundation

/// 内置的 ntfs-3g（打过 OpenNTFS 补丁，允许普通用户挂载块设备，以配合 macFUSE 的 FSKit 后端）。
enum NTFS3G {
    /// 优先用 App 内置版本；开发时用 vendor/dist；最后退回 Homebrew 版本（Homebrew 版不能以普通用户挂载硬盘）。
    static var bundledPath: String? {
        let fm = FileManager.default
        if let url = Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Helpers/ntfs-3g"),
           fm.isExecutableFile(atPath: url.path) {
            return url.path
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/dist/bin/ntfs-3g").path
        return fm.isExecutableFile(atPath: dev) ? dev : nil
    }

    /// FSKit 后端的挂载选项。
    /// - streams_interface=openxattr：允许 macOS 的 com.apple.* 扩展属性（存为 NTFS 命名数据流），
    ///   否则 Finder 复制文件会因扩展属性失败（错误 100102）。
    /// - 不能用 auto_xattr：那是内核扩展后端才实现的功能，FSKit 下会直接报「不支持」。
    static func fskitOptions(volumeName: String) -> [String] {
        let name = volumeName.replacingOccurrences(of: ",", with: " ")
        return [
            "backend=fskit", "noalerts", "local", "noappledouble", "windows_names",
            "streams_interface=openxattr", "volname=\(name)",
        ].flatMap { ["-o", $0] }
    }

    /// 为卷选一个可用的 /Volumes 挂载点（不创建目录：FSKit 下由 macFUSE 自己创建）。
    static func pickMountPoint(for volumeName: String) -> String {
        var base = volumeName
            .components(separatedBy: CharacterSet(charactersIn: "/:\0")).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        if base.isEmpty { base = "NTFS" }
        base = String(base.prefix(64))
        let fm = FileManager.default
        let mounted = Set(MountEntry.all().map(\.on))
        var mp = "/Volumes/\(base)", i = 1
        while mounted.contains(mp) || ((try? fm.contentsOfDirectory(atPath: mp))?.isEmpty == false) {
            mp = "/Volumes/\(base) \(i)"; i += 1
        }
        return mp
    }

    // MARK: - 进程扫描

    struct Running {
        let pid: pid_t
        let device: String      // /dev/disk4s1
        let mountPoint: String  // /Volumes/xxx
    }

    /// 当前正在运行的 ntfs-3g 进程及其设备/挂载点（只能看到本用户的进程，FSKit 模式下正好如此）。
    static func running() -> [Running] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        var result: [Running] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var nameBuf = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0,
                  String(cString: nameBuf) == "ntfs-3g",
                  let args = arguments(of: pid) else { continue }
            // 位置参数：<设备> <挂载点>，跳过 -o xxx 之类的选项
            var positional: [String] = []
            var i = 1
            while i < args.count {
                let a = args[i]
                if a == "-o" { i += 2; continue }
                if a.hasPrefix("-") { i += 1; continue }
                positional.append(a); i += 1
            }
            if positional.count >= 2 {
                var device = positional[0]
                // 实体硬盘通过 fdmount 以 /dev/fd/N 传入，查出该句柄实际指向的设备
                if device.hasPrefix("/dev/fd/"), let fd = Int32(device.dropFirst(8)),
                   let real = vnodePath(pid: pid, fd: fd) {
                    device = real
                }
                result.append(Running(pid: pid, device: device, mountPoint: positional[1]))
            }
        }
        return result
    }

    /// 进程某个文件句柄对应的路径（如 /dev/disk15s1）。
    private static func vnodePath(pid: pid_t, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// 通过 KERN_PROCARGS2 读取进程参数。
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = MemoryLayout<Int32>.size
        // 跳过可执行文件路径及其后的填充 \0
        while idx < size, buf[idx] != 0 { idx += 1 }
        while idx < size, buf[idx] == 0 { idx += 1 }

        var args: [String] = []
        while args.count < Int(argc), idx < size {
            let start = idx
            while idx < size, buf[idx] != 0 { idx += 1 }
            args.append(String(decoding: buf[start..<idx], as: UTF8.self))
            idx += 1
        }
        return args
    }
}
