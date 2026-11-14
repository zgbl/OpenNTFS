import ServiceManagement
import SwiftUI

// MARK: - 菜单栏面板

struct MenuContentView: View {
    @EnvironmentObject var monitor: DiskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenNTFS").font(.headline)
                Spacer()
                Button {
                    monitor.recheckDependencies()
                    monitor.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新")
            }

            if !monitor.deps.ready {
                Banner(icon: "exclamationmark.triangle.fill", color: .orange,
                       text: "缺少 \(monitor.deps.missingDescription)，目前只能只读。请到「设置」安装。")
            }

            if monitor.volumes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("未检测到 NTFS 磁盘").foregroundStyle(.secondary)
                    Text("插入 Windows 格式的移动硬盘或 U 盘后会自动出现")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(monitor.volumes) { v in
                    VolumeRow(volume: v)
                }
            }

            if let err = monitor.lastError {
                Banner(icon: "xmark.octagon.fill", color: .red, text: err) {
                    monitor.lastError = nil
                }
            } else if let msg = monitor.lastMessage {
                Banner(icon: "checkmark.circle.fill", color: .green, text: msg) {
                    monitor.lastMessage = nil
                }
            }

            Divider()
            HStack {
                SettingsLink { Text("设置…") }
                    .buttonStyle(.borderless)
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { monitor.refresh() }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var monitor: DiskMonitor
    let volume: NTFSVolume

    private var busy: Bool { monitor.busy.contains(volume.bsdName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 22))
                    .foregroundStyle(stateColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.displayName).font(.body.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusPill(text: volume.driverLabel, color: stateColor)
            }

            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("处理中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    actions
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder private var actions: some View {
        switch volume.state {
        case .readWrite:
            Button("打开") { monitor.openInFinder(volume) }
            Button("切换为只读") { Task { await monitor.switchToReadOnly(volume) } }
        case .readOnly:
            Button("启用读写") { Task { await monitor.mountReadWrite(volume) } }
                .buttonStyle(.borderedProminent)
                .disabled(!monitor.deps.ready)
            Button("打开") { monitor.openInFinder(volume) }
        case .unmounted:
            Button("读写挂载") { Task { await monitor.mountReadWrite(volume) } }
                .buttonStyle(.borderedProminent)
                .disabled(!monitor.deps.ready)
            Button("只读挂载") { Task { await monitor.mountReadOnly(volume) } }
        }
        Spacer()
        if volume.state != .unmounted {
            Button { Task { await monitor.unmount(volume) } } label: {
                Image(systemName: "stop.circle")
            }.help("卸载")
        }
        if !volume.isInternal {
            Button { Task { await monitor.eject(volume) } } label: {
                Image(systemName: "eject")
            }.help("推出（可安全拔出）")
        }
    }

    private var subtitle: String {
        var parts = [ByteCountFormatter.string(fromByteCount: volume.size, countStyle: .file), volume.bsdName]
        if let m = volume.deviceModel, !m.isEmpty { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private var stateColor: Color {
        switch volume.state {
        case .readWrite: .green
        case .readOnly: .orange
        case .unmounted: .secondary
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct Banner: View {
    let icon: String
    let color: Color
    let text: String
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

// MARK: - 设置窗口

struct SettingsView: View {
    @EnvironmentObject var monitor: DiskMonitor
    @AppStorage(Prefs.autoMountKey) private var autoMount = true
    @AppStorage(Prefs.fskitKey) private var useFSKit = true
    @State private var passwordless = Privileged.passwordlessInstalled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var working = false
    @State private var note: String?

    var body: some View {
        Form {
            Section("依赖组件") {
                DepRow(name: "macFUSE", ok: monitor.deps.macFUSE, detail: "用户态文件系统框架")
                DepRow(name: "ntfs-3g", ok: monitor.deps.ntfs3gPath != nil,
                       detail: NTFS3G.bundledPath != nil ? "已内置（OpenNTFS 补丁版）" : (monitor.deps.ntfs3gPath ?? "开源 NTFS 读写驱动"))
                if !monitor.deps.ready {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在终端中运行以下命令安装（需要 Homebrew）：").font(.caption)
                        Text(Dependencies.installCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        HStack {
                            Button("复制命令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Dependencies.installCommand, forType: .string)
                            }
                            Button("在终端中运行") { openTerminal(Dependencies.installCommand) }
                            Button("重新检测") { monitor.recheckDependencies() }
                        }
                        Text("ntfs-3g 已内置在 OpenNTFS 中，只需安装 macFUSE。macOS 15.4 及以上默认使用 FSKit 方式，无需内核扩展、无需降低系统安全性。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("挂载") {
                Toggle("插入外接 NTFS 磁盘时自动以读写模式挂载", isOn: $autoMount)
                Toggle("使用 FSKit 方式（推荐，无需内核扩展）", isOn: $useFSKit)
                if !useFSKit {
                    Text("内核扩展方式需要在恢复模式中开启「降低安全性」，并在「隐私与安全性」中允许 macFUSE。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("挂载时不再询问管理员密码", isOn: Binding(
                    get: { passwordless },
                    set: { newValue in Task { await setPasswordless(newValue) } }))
                .disabled(working)
                Text("开启后会把一个只能执行挂载/卸载的助手脚本安装到 /Library/PrivilegedHelperTools，并在 /etc/sudoers.d 中只允许当前用户免密码运行它。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(.red)
            }

            Section {
                Text("⚠️ 拔出硬盘前请务必点「推出」，否则可能导致 NTFS 文件系统损坏。若 Windows 开启了「快速启动」，磁盘会处于休眠状态而无法读写，请在 Windows 中关闭该选项。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            monitor.recheckDependencies()
            passwordless = Privileged.passwordlessInstalled
        }
    }

    private func setPasswordless(_ on: Bool) async {
        working = true
        note = nil
        UserDefaults.standard.set(on, forKey: Prefs.passwordlessKey)
        let r = on ? await Privileged.installPasswordless() : await Privileged.uninstallPasswordless()
        if !r.ok { note = "操作失败：" + (r.stderr.isEmpty ? r.stdout : r.stderr) }
        passwordless = Privileged.passwordlessInstalled
        working = false
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note = "设置登录启动失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func openTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        Task { _ = await Shell.run("/usr/bin/osascript", ["-e", script]) }
    }
}

struct DepRow: View {
    let name: String
    let ok: Bool
    let detail: String
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(name)
            Spacer()
            Text(ok ? detail : "未安装").font(.caption).foregroundStyle(.secondary)
        }
    }
}
