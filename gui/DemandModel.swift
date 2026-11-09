import SwiftUI
import AppKit

final class TetherModel: ObservableObject {
    @Published var service: [String: String] = [:]
    @Published var busy = false
    @Published var targetsText = ""
    @Published var ipv6Address = ""
    @Published var down = "—"
    @Published var up = "—"
    @Published var message = ""
    @Published var diagnostic = "点击检查连接，查看手机与 Clash 分流组。"
    @Published var isError = false
    @Published var diagnosticBusy = false
    @Published var legacyInstalled = FileManager.default.fileExists(atPath: LegacyPaths.daemon)
    private var saved = DemandPreferences.load()
    private var timer: Timer?
    @Published private(set) var coordinating = false
    private var reading = false, clashSelected = false
    private var previous: (Date, Double, Double)?
    private var guardian: Process?

    var resources: String { appResourcesDirectory() }
    var cli: String { resources + "/rndis-tether" }
    var helper: String { resources + "/rndis-tether-gui-helper" }
    var config: DemandPreferences {
        DemandPreferences(targets: targetsText.components(separatedBy: .newlines))
    }
    var dirty: Bool { !FileManager.default.fileExists(atPath: UserFiles.settings.path) || saved != (try? config.validated()) }
    var ownsSession: Bool { service["owner-pid"] == String(getpid()) }
    var online: Bool { ownsSession && service["state"] == "online" }
    var title: String {
        if legacyInstalled && !ownsSession { return "检测到旧版常驻后台" }
        if !ownsSession { return "按需连接未启动" }
        switch service["state"] {
        case "online": return "手机已连接"
        case "no-phone": return "等待手机连接"
        case "connecting": return "正在建立连接"
        case "sleeping": return "手机正在休眠"
        case "paused": return "手机连接已暂停"
        default: return "正在等待手机网络"
        }
    }
    var advice: String {
        if legacyInstalled && !ownsSession { return "首次启动连接会授权迁移旧版，清理本程序的常驻后台、目标路由和专用 DNS。" }
        if !ownsSession { return "点击启动连接并授权。手机 USB 网络会在本次前端运行期间提供服务。" }
        if !online { return "请连接手机并开启 USB 网络共享，后台会自动检测。" }
        return "手机 USB 网络已就绪。目标分流由 Clash 的 RNDIS Tether 分流组负责。"
    }

    init(poll: Bool = true) {
        targetsText = saved.targets.joined(separator: "\n")
        if poll {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    private func persistConfiguration() throws -> DemandPreferences {
        let value = try config.validated()
        try value.save()
        saved = value
        return value
    }

    func save() {
        do {
            try persistConfiguration().installClashScript()
            show("配置已保存，Clash 全局脚本已覆盖为 RNDIS 专用脚本。请在 Clash Verge 点击“重新激活订阅”加载。", error: false)
        } catch { show(error.localizedDescription, error: true) }
    }

    func revealScript() {
        do {
            _ = try persistConfiguration()
            NSWorkspace.shared.activateFileViewerSelecting([UserFiles.clashScript])
            show("RNDIS 专用脚本已导出到用户目录。", error: false)
        } catch { show(error.localizedDescription, error: true) }
    }

    func refresh(coordinate: Bool = true) {
        guard !reading, !busy else { return }
        reading = true
        let executable = cli
        DispatchQueue.global(qos: .utility).async {
            let response = try? command(executable, ["status", "--raw"])
            let raw = fields(response?.text ?? "")
            let status = raw["protocol"] == "1" ? raw : [:]
            var address = ""
            let interface = status["interface"] ?? "feth50"
            if matches(interface, "^feth[0-9]{1,10}$"),
               let result = try? command("/sbin/ifconfig", [interface]), result.code == 0 {
                for line in result.text.split(separator: "\n") {
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    if fields.count >= 2, fields[0] == "inet6", let value = ipv6(String(fields[1])) { address = value; break }
                }
            }
            DispatchQueue.main.async {
                self.service = status
                self.ipv6Address = address
                self.legacyInstalled = FileManager.default.fileExists(atPath: LegacyPaths.daemon)
                let now = Date(), rx = Double(status["rx-bytes"] ?? "") ?? 0, tx = Double(status["tx-bytes"] ?? "") ?? 0
                if let (date, oldRX, oldTX) = self.previous, rx >= oldRX, tx >= oldTX, self.online {
                    let elapsed = max(now.timeIntervalSince(date), 0.1)
                    self.down = Self.speed((rx - oldRX) / elapsed)
                    self.up = Self.speed((tx - oldTX) / elapsed)
                } else { self.down = "—"; self.up = "—" }
                self.previous = (now, rx, tx)
                self.reading = false
                if coordinate { self.coordinateClash() }
            }
        }
    }

    private static func speed(_ bytes: Double) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB/s", bytes / 1_048_576) : String(format: "%.1f KB/s", bytes / 1024)
    }

    private func coordinateClash() {
        guard !coordinating, !busy else { return }
        let ready = online && !saved.targets.isEmpty
        let needsRecovery = FileManager.default.fileExists(atPath: UserFiles.journal.path)
        guard ready || clashSelected || needsRecovery else { return }
        var restorationOwner = getpid()
        if let data = try? Data(contentsOf: UserFiles.journal),
           let journal = try? JSONDecoder().decode(ClashSelection.self, from: data), journal.owner != getpid() {
            if kill(journal.owner, 0) == 0 { return }
            restorationOwner = journal.owner
        }
        coordinating = true
        let owner = getpid()
        let recoverOwner = restorationOwner
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                if ready {
                    let client = try ClashControl.discover()
                    if recoverOwner != owner { try client.restore(owner: recoverOwner) }
                    // Recheck after Clash restarts or reloads its profile.
                    if try client.selection() != ClashControl.usb || !needsRecovery {
                        try client.enableUSB(owner: owner)
                    }
                } else { try ClashControl.restore(owner: recoverOwner) }
            }
            DispatchQueue.main.async {
                self.coordinating = false
                switch result {
                case .success:
                    if ready && !self.clashSelected { self.show("Clash 分流组已切到手机 USB。", error: false) }
                    self.clashSelected = ready
                case .failure(let error): self.show(error.localizedDescription, error: true)
                }
            }
        }
    }

    func start() {
        guard !busy, !coordinating, !ownsSession else { return }
        do {
            let value = try persistConfiguration()
            if !value.targets.isEmpty { try value.installClashScript() }
            if let data = try? Data(contentsOf: UserFiles.journal) {
                let journal = try JSONDecoder().decode(ClashSelection.self, from: data)
                if journal.owner != getpid() && kill(journal.owner, 0) == 0 {
                    throw TetherError("另一个前端仍持有 Clash 分流组，请先退出该前端。")
                }
                try ClashControl.restore()
            }
            let watch = Process()
            watch.executableURL = URL(fileURLWithPath: helper)
            watch.arguments = ["watch-demand", String(getpid())]
            watch.standardInput = FileHandle.nullDevice
            watch.standardOutput = FileHandle.nullDevice
            watch.standardError = FileHandle.nullDevice
            try watch.run()
            guardian?.terminate()
            guardian = watch
            busy = true
            show("等待管理员授权启动本次 USB 连接…", error: false)
            let line = [helper, "start-demand", resources, String(getpid())].map(shellQuote).joined(separator: " ")
            let script = "do shell script " + appleScriptLiteral(line) + " with administrator privileges"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try command("/usr/bin/osascript", ["-e", script], timeout: 240) }
                DispatchQueue.main.async {
                    self.busy = false
                    switch result {
                    case .success(let output) where output.code == 0:
                        self.show(output.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n脚本更新后，请在 Clash Verge 点击“重新激活订阅”。", error: false)
                    case .success(let output):
                        self.guardian?.terminate(); self.guardian = nil
                        self.show(output.text.trimmingCharacters(in: .whitespacesAndNewlines), error: true)
                    case .failure(let error):
                        self.guardian?.terminate(); self.guardian = nil
                        self.show(error.localizedDescription, error: true)
                    }
                    self.refresh()
                }
            }
        } catch { show(error.localizedDescription, error: true) }
    }

    func stop(quit: Bool = false) {
        guard !busy, !coordinating else { return }
        busy = true
        let executable = cli, owner = getpid()
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            do { try ClashControl.restore(owner: owner) } catch { errors.append(error.localizedDescription) }
            let status = fields((try? command(executable, ["status", "--raw"]).text) ?? "")
            if status["owner-pid"] == String(owner) {
                do {
                    _ = try checked(executable, ["stop-on-demand"], timeout: 12)
                    let deadline = Date().addingTimeInterval(12)
                    while Date() < deadline {
                        let current = fields(try command(executable, ["status", "--raw"]).text)
                        if current["owner-pid"] != String(owner) { break }
                        usleep(100_000)
                    }
                    if fields(try command(executable, ["status", "--raw"]).text)["owner-pid"] == String(owner) {
                        throw TetherError("USB 后台仍在停止，请稍后检查状态。")
                    }
                }
                catch { errors.append(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.clashSelected = false
                if errors.isEmpty { self.guardian?.terminate(); self.guardian = nil }
                self.show(errors.isEmpty ? "本次 USB 连接已停止，Clash 已恢复原选择。" : errors.joined(separator: "\n"), error: !errors.isEmpty)
                self.refresh()
                if quit { NSApp.terminate(nil) }
            }
        }
    }

    func diagnose(testHTTPS: Bool = false) {
        guard !diagnosticBusy, !busy else { return }
        diagnosticBusy = true
        let executable = helper
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try command(executable, ["diagnose-demand", "feth50"] + (testHTTPS ? ["--https"] : []), timeout: 60) }
            DispatchQueue.main.async {
                self.diagnosticBusy = false
                switch result {
                case .success(let output): self.diagnostic = output.text
                case .failure(let error): self.diagnostic = error.localizedDescription
                }
            }
        }
    }

    func show(_ text: String, error: Bool) { message = text; isError = error }
}
