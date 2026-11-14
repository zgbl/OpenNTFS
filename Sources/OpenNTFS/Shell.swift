import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// 在后台线程运行一个进程并等待结果。
    static func run(_ launchPath: String, _ args: [String], env: [String: String] = [:]) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                if !env.isEmpty {
                    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
                }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: ShellResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ShellResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// 单引号转义，供 /bin/sh 使用。
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 负责以 root 身份执行特权助手脚本。
/// - 若已开启「免密码」（助手已安装到系统目录且 sudoers 已配置），通过 `sudo -n` 执行；
/// - 否则通过 AppleScript 弹出系统管理员密码框。
enum Privileged {
    static let installedHelper = "/Library/PrivilegedHelperTools/local.openntfs.helper"
    static let sudoersFile = "/etc/sudoers.d/openntfs"

    static var bundledHelper: String {
        if let url = Bundle.main.url(forResource: "ntfs-helper", withExtension: "sh") {
            return url.path
        }
        // 开发时用 `swift run` 直接运行的情况
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ntfs-helper.sh").path
        return dev
    }

    static var passwordlessInstalled: Bool {
        FileManager.default.fileExists(atPath: installedHelper)
            && FileManager.default.fileExists(atPath: sudoersFile)
    }

    static var askpass: String {
        if let url = Bundle.main.url(forResource: "askpass", withExtension: "sh") { return url.path }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/askpass.sh").path
    }

    /// 以 root 运行助手脚本。
    /// 必须由本进程直接启动 sudo，不能用 AppleScript 的 `with administrator privileges`：
    /// 后者经由系统的 authtrampoline 中转，macOS 隐私保护会把「发起 App」算成 authtrampoline，
    /// 导致授予 OpenNTFS 的「完全磁盘访问权限」不生效，打开外接硬盘被拒（实测 macOS 27）。
    static func helper(_ args: [String]) async -> ShellResult {
        if passwordlessInstalled {
            let r = await Shell.run("/usr/bin/sudo", ["-n", installedHelper] + args)
            if !isSudoAuthFailure(r) { return r }
        }
        // sudo -A：通过 askpass 弹出密码框
        let r = await Shell.run("/usr/bin/sudo", ["-A", bundledHelper] + args,
                                env: ["SUDO_ASKPASS": askpass])
        if isSudoAuthFailure(r) {
            return ShellResult(status: -128, stdout: "", stderr: "已取消授权（或密码错误）")
        }
        return r
    }

    /// sudo 自身认证失败（而不是被执行的命令失败）
    private static func isSudoAuthFailure(_ r: ShellResult) -> Bool {
        r.status == 1 && (r.stderr.contains("sudo: a password is required")
            || r.stderr.contains("sudo: no password was provided")
            || r.stderr.contains("incorrect password attempt")
            || r.stderr.contains("sudo: a terminal is required"))
    }

    /// 通过 osascript 以管理员权限执行 shell 命令（系统会弹出密码框）。
    static func runAsAdmin(_ shellCommand: String) async -> ShellResult {
        // 把 stderr 合并进来，并把真实退出码放在最后一行，方便解析
        let wrapped = "{ \(shellCommand) ; } 2>&1; echo \"__RC=$?\""
        let escaped = wrapped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"OpenNTFS 需要管理员权限来挂载 NTFS 磁盘。\""
        let r = await Shell.run("/usr/bin/osascript", ["-e", script])
        guard r.ok else {
            // -128 = 用户点了取消
            if r.stderr.contains("-128") {
                return ShellResult(status: -128, stdout: "", stderr: "已取消授权")
            }
            return r
        }
        var lines = r.stdout.components(separatedBy: CharacterSet.newlines)
        var status: Int32 = 0
        if let last = lines.last, last.hasPrefix("__RC=") {
            status = Int32(last.dropFirst(5)) ?? 1
            lines.removeLast()
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0
            ? ShellResult(status: 0, stdout: text, stderr: "")
            : ShellResult(status: status, stdout: "", stderr: text)
    }

    /// 安装免密码配置：把助手复制到 root 拥有的系统目录，并只允许当前用户无密码执行这一个文件。
    static func installPasswordless() async -> ShellResult {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return ShellResult(status: 2, stdout: "", stderr: "用户名包含不支持的字符")
        }
        let tmp = "/tmp/openntfs.sudoers.\(getpid())"
        let line = "\(user) ALL=(root) NOPASSWD: \(installedHelper)"
        let cmd = """
        set -e; \
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools; \
        install -o root -g wheel -m 755 \(Shell.quote(bundledHelper)) \(installedHelper); \
        printf '%s\\n' \(Shell.quote(line)) > \(tmp); \
        visudo -cf \(tmp) >/dev/null; \
        install -o root -g wheel -m 440 \(tmp) \(sudoersFile); \
        rm -f \(tmp)
        """
        return await runAsAdmin(cmd)
    }

    static func uninstallPasswordless() async -> ShellResult {
        await runAsAdmin("rm -f \(sudoersFile) \(installedHelper)")
    }
}
