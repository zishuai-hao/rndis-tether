import SwiftUI
import AppKit

final class TetherModel: ObservableObject {
    @Published var service: [String: String] = [:]
    @Published var installed = FileManager.default.fileExists(atPath: Paths.daemon)
    @Published var busy = false
    @Published var targetsText = ""
    @Published var routeEnabled = true
    @Published var preferPhone = false
    @Published var dnsServer = ""
    @Published var ipv6Address = ""
    @Published var down = "—"
    @Published var up = "—"
    @Published var message = ""
    @Published var isError = false
    @Published var diagnostic = "点击“检查路由”，查看手机 IPv6 网关、目标解析结果及当前 /128 路由。"
    @Published var diagnosticBusy = false
    private var timer: Timer?
    private var reading = false
    private var previous: (Date, Double, Double)?
    private var savedConfig: GUIConfig?

    let resources = Bundle.main.resourceURL!.path
    var cli: String { resources + "/rndis-tether" }
    var helper: String { resources + "/rndis-tether-gui-helper" }
    var config: GUIConfig {
        GUIConfig(enabled: routeEnabled, preferPhone: preferPhone,
                  targets: targetsText.components(separatedBy: .newlines), dnsServer: dnsServer)
    }
    var dirty: Bool { savedConfig == nil || (try? config.validated()) != savedConfig }
    var online: Bool { service["state"] == "online" }
    var title: String {
        switch service["state"] {
        case "online": return "手机已连接"
        case "no-phone": return "等待手机连接"
        case "paused": return "连接已暂停"
        case "sleeping": return "手机正在休眠"
        case "connecting": return "正在建立连接"
        case "retrying": return "正在重试连接"
        case "unsupported": return "设备暂不受支持"
        case .some(let state): return "状态：" + state
        case .none: return installed ? "后台服务未运行" : "尚未安装后台服务"
        }
    }
    var advice: String {
        if let problem = service["problem"] ?? service["settings-problem"], !problem.isEmpty { return problem }
        if !installed { return "配置目标并安装服务，之后会随 Mac 启动并自动处理手机重连。" }
        if service["state"] == "paused" { return "点击恢复连接，即可重新使用手机网络。" }
        if !online { return "连接 USB 数据线，在手机设置中开启 USB 网络共享。" }
        if ipv6Address.isEmpty { return "USB 已连接，尚无可用 IPv6。请关闭手机 Wi-Fi，保持移动数据开启。" }
        if savedConfig?.enabled == true { return "USB 网络已就绪。自动路由会随网络变化更新，关闭窗口后后台服务继续运行。" }
        return "USB 网络已就绪。配置目标并保存后可启用自动路由，关闭窗口后后台服务继续运行。"
    }

    init(poll: Bool = true) {
        savedConfig = GUIConfig.load()
        if let config = savedConfig {
            routeEnabled = config.enabled
            preferPhone = config.preferPhone
            targetsText = config.targets.joined(separator: "\n")
            dnsServer = config.dnsServer
        } else if let data = FileManager.default.contents(atPath: "/etc/rndis-tether-route-domains") {
            // Migrate only the visible draft; no system setting is changed on launch.
            targetsText = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                String($0.split(separator: "#", omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if poll {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        guard !reading, !busy else { return }
        reading = true
        let executable = cli
        DispatchQueue.global(qos: .utility).async {
            let result = try? command(executable, ["status", "--raw"])
            let values = fields(result?.text ?? "")
            let valid = values["protocol"] == "1" ? values : [:]
            let interface = valid["interface"] ?? "feth50"
            var address = ""
            if matches(interface, "^feth[0-9]{1,10}$"), let output = try? command("/sbin/ifconfig", [interface]), output.code == 0 {
                for line in output.text.split(separator: "\n") {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    if parts.count >= 2, parts[0] == "inet6", let value = ipv6(String(parts[1].split(separator: "%")[0])) {
                        address = value; break
                    }
                }
            }
            DispatchQueue.main.async {
                self.service = valid
                self.ipv6Address = address
                self.installed = FileManager.default.fileExists(atPath: Paths.daemon)
                let now = Date(), rx = Double(valid["rx-bytes"] ?? "") ?? 0, tx = Double(valid["tx-bytes"] ?? "") ?? 0
                if let (date, previousRX, previousTX) = self.previous, rx >= previousRX, tx >= previousTX, self.online {
                    let seconds = max(now.timeIntervalSince(date), 0.1)
                    self.down = Self.speed((rx - previousRX) / seconds)
                    self.up = Self.speed((tx - previousTX) / seconds)
                } else { self.down = "—"; self.up = "—" }
                self.previous = (now, rx, tx)
                self.reading = false
            }
        }
    }

    private static func speed(_ value: Double) -> String {
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        return String(format: "%.1f KB/s", value / 1024)
    }

    func apply() {
        do {
            let validated = try config.validated()
            let payload = try validated.encoded().base64EncodedString()
            authorized(["install", resources, payload]) {
                self.savedConfig = validated
                self.diagnose()
            }
        } catch { show(error.localizedDescription, error: true) }
    }

    func uninstall() { authorized(["uninstall"]) { self.savedConfig = nil } }

    private func authorized(_ arguments: [String], success: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        message = "等待管理员授权…"
        isError = false
        // Both shell and AppleScript are quoted independently. User input is passed
        // as one base64 JSON argument, validated again by the privileged executable.
        let line = ([helper] + arguments).map(shellQuote).joined(separator: " ")
        let script = "do shell script " + appleScriptLiteral(line) + " with administrator privileges"
        let preflight = helper
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<CommandResult, Error> = Result {
                _ = try checked(preflight, ["check-system-paths"])
                return try command("/usr/bin/osascript", ["-e", script], timeout: 240)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let output) where output.code == 0:
                    success()
                    self.show(output.text.trimmingCharacters(in: .whitespacesAndNewlines), error: false)
                case .success(let output):
                    if output.text.contains("(-128)") { self.show("已取消管理员授权，配置未应用。", error: false) }
                    else { self.show(output.text.trimmingCharacters(in: .whitespacesAndNewlines), error: true) }
                case .failure(let error): self.show(error.localizedDescription, error: true)
                }
                self.refresh()
            }
        }
    }

    func pauseOrResume() {
        guard !busy else { return }
        busy = true
        let paused = service["state"] == "paused"
        let executable = cli
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try checked(executable, [paused ? "connect" : "disconnect"]) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success: self.show(paused ? "已恢复连接。" : "连接已暂停。", error: false)
                case .failure(let error): self.show(error.localizedDescription, error: true)
                }
                self.refresh()
            }
        }
    }

    func diagnose(testHTTPS: Bool = false) {
        guard !diagnosticBusy, !busy else { return }
        do {
            let payload = try config.validated().encoded().base64EncodedString()
            let executable = helper, interface = service["interface"] ?? "feth50"
            diagnosticBusy = true
            DispatchQueue.global(qos: .utility).async {
                let arguments = ["diagnose", payload, interface] + (testHTTPS ? ["--https"] : [])
                let result = Result { try command(executable, arguments, timeout: testHTTPS ? 90 : 30) }
                DispatchQueue.main.async {
                    self.diagnosticBusy = false
                    switch result {
                    case .success(let output):
                        self.diagnostic = output.text
                        if output.code != 0 {
                            let applied = self.savedConfig != nil && self.savedConfig == (try? self.config.validated())
                            self.show(applied ? "配置已保存；网络检查尚未通过，请查看诊断详情。" : "草稿网络检查尚未通过；尚未应用这些配置。", error: true)
                        }
                        else { self.show(testHTTPS ? "目标路由与公共 HTTPS 探测通过；目标服务器的 HTTPS 尚未测试。" : "目标路由检查通过；尚未测试 HTTPS。", error: false) }
                    case .failure(let error): self.diagnostic = error.localizedDescription
                    }
                }
            }
        } catch { show(error.localizedDescription, error: true) }
    }

    func show(_ text: String, error: Bool) { message = text; isError = error }
}

private struct Metric: View {
    var name: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).lineLimit(1).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MainView: View {
    @ObservedObject var model: TetherModel
    @State private var showUninstall = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connection
                    routing
                    diagnostics
                }.padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 730, idealWidth: 790, maxWidth: .infinity, minHeight: 700, idealHeight: 790)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("卸载后台服务？", isPresented: $showUninstall) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) { model.uninstall() }
        } message: {
            Text("将停止 USB 网络共享服务，删除它的配置，并清理本应用管理的路由与专用 DNS。应用本身会保留。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [Color(red: 0.12, green: 0.63, blue: 0.58), Color(red: 0.06, green: 0.35, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("RNDIS Tether").font(.title2.weight(.semibold))
                Text("Android USB 网络 · IPv6 自动分流").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("macOS 原生版 · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var connection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Circle().fill(model.online ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(model.title).font(.headline)
                    Spacer()
                    if !model.service.isEmpty {
                        Button(model.service["state"] == "paused" ? "恢复连接" : "暂停连接") { model.pauseOrResume() }.disabled(model.busy)
                    }
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新状态").disabled(model.busy)
                }
                HStack(spacing: 24) {
                    Metric(name: "手机", value: model.service["phone"] ?? "未检测到")
                    Metric(name: "USB IPv4", value: model.service["address"] ?? "—")
                    Metric(name: "当前默认接口", value: model.service["primary"] ?? "—")
                }
                HStack(spacing: 24) {
                    Metric(name: "USB IPv6", value: model.ipv6Address.isEmpty ? "未就绪" : model.ipv6Address)
                    Metric(name: "下载 / 上传", value: "↓ \(model.down)   ↑ \(model.up)")
                }
                Text(model.advice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }

    private var routing: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("为指定目标自动维护 IPv6 路由", isOn: $model.routeEnabled).font(.headline)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("目标域名或 IPv6 地址").font(.subheadline.weight(.medium))
                        TextEditor(text: $model.targetsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 84).padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                            .accessibilityLabel("路由目标，每行一个")
                        Text("每行一个，最多 8 个；例如 server.example.com。\n仅配置这些地址的 /128 路由，手机重连后自动更新。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("网络偏好").font(.subheadline.weight(.medium))
                        Toggle("优先使用手机上网", isOn: $model.preferPhone)
                        Text(model.preferPhone ? "日常流量也优先走手机，可能产生移动数据费用。" : "关闭时保留 Wi-Fi 等网络的默认优先级，指定目标走手机。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("域名专用 DNS（可选）").font(.subheadline.weight(.medium)).padding(.top, 2)
                        TextField("留空：沿用系统 DNS", text: $model.dnsServer)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("域名专用 DNS 服务器")
                        Text("仅对上述域名生效。系统 DNS 没有 AAAA 结果时可填写 DNS 服务器 IP。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(width: 255)
                }
            }.padding(12).disabled(model.busy)
        }
    }

    private var diagnostics: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("路由诊断", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    if model.diagnosticBusy { ProgressView().controlSize(.small) }
                    Button("检查路由") { model.diagnose() }.disabled(model.busy || model.diagnosticBusy)
                    Button("探测公网 HTTPS") { model.diagnose(testHTTPS: true) }.disabled(model.busy || model.diagnosticBusy)
                }
                ScrollView {
                    Text(model.diagnostic).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 90)
            }.padding(12)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.isError ? "exclamationmark.circle.fill" : "info.circle")
                    Text(model.message).textSelection(.enabled).lineLimit(5)
                }.font(.callout).foregroundStyle(model.isError ? Color.red : Color.secondary)
            }
            HStack {
                if model.installed {
                    Button("卸载服务…", role: .destructive) { showUninstall = true }.disabled(model.busy)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.busy ? "正在处理，请稍候" : model.dirty ? "有待应用的配置 · 保存需要管理员授权" : "配置已保存 · 后台服务随系统启动")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.installed ? "保存并应用" : "安装并应用") { model.apply() }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.05, green: 0.46, blue: 0.44))
                    .disabled(model.busy).keyboardShortcut("s", modifiers: .command)
            }
            HStack(spacing: 4) {
                Text("原作者")
                Link("stlk0", destination: URL(string: "https://github.com/stlk0")!)
                Text("·")
                Link("上游 rndis-tether", destination: URL(string: "https://github.com/stlk0/rndis-tether")!)
                Text("· MIT · zishuai-hao 独立分支")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
}

struct MenuContent: View {
    @ObservedObject var model: TetherModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.title)
        if let phone = model.service["phone"] { Text(phone) }
        Divider()
        Button("打开控制面板") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if !model.service.isEmpty {
            Button(model.service["state"] == "paused" ? "恢复连接" : "暂停连接") { model.pauseOrResume() }.disabled(model.busy)
        }
        Divider()
        Button("退出界面（后台服务继续运行）") { NSApp.terminate(nil) }.disabled(model.busy)
    }
}

struct TetherApp: App {
    @StateObject private var model = TetherModel()
    var body: some Scene {
        Window("RNDIS Tether", id: "main") { MainView(model: model) }.defaultSize(width: 790, height: 790)
        MenuBarExtra("RNDIS Tether", systemImage: "cable.connector.horizontal") { MenuContent(model: model) }
    }
}

@main
enum AppEntry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            // Offscreen view rendering for layout QA; no status mutation or privilege prompt.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let model = TetherModel(poll: false)
            model.refresh()
            let frame = NSRect(x: 0, y: 0, width: 790, height: 850)
            let view = NSHostingView(rootView: MainView(model: model))
            view.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                view.layoutSubtreeIfNeeded()
                view.display()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: URL(fileURLWithPath: path)); print("View rendered: " + path); exit(0) }
                catch { print(error.localizedDescription); exit(1) }
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            let root = Bundle.main.resourceURL!.path
            let ok = ["rndis-tether", "rndis-tether-gui-helper"].allSatisfy { FileManager.default.isExecutableFile(atPath: root + "/" + $0) }
            print(ok ? "App resources OK" : "App resources missing")
            exit(ok ? 0 : 1)
        }
        TetherApp.main()
    }
}
