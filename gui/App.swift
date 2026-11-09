import SwiftUI
import AppKit

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

    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [Color(red: 0.12, green: 0.63, blue: 0.58), Color(red: 0.06, green: 0.35, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("RNDIS Tether").font(.title2.weight(.semibold))
                Text("按需 USB 网络 · Clash 双栈分流").font(.subheadline).foregroundStyle(.secondary)
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
                Text("通过 Clash 按目标和端口分流").font(.headline)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("目标域名、IP 或 CIDR").font(.subheadline.weight(.medium))
                        TextEditor(text: $model.targetsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 84).padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                            .accessibilityLabel("路由目标，每行一个")
                        Text("每行一个目标，最多 8 个，可附加端口或范围。\n例如 example.com:443、192.0.2.0/24:8000-8100、[2001:db8::/64]:443").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Clash DNS（可选）").font(.subheadline.weight(.medium))
                        TextField("留空：沿用 Clash DNS", text: $model.dnsServer)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("域名专用 DNS 服务器")
                        Text("仅写入导出的 Clash 脚本。首次使用需将脚本合并到 Clash Verge 的全局扩展脚本，使用规则模式。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(width: 255)
                }
            }.padding(12).disabled(model.busy)
        }
    }

    private var diagnostics: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("连接诊断", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    if model.diagnosticBusy { ProgressView().controlSize(.small) }
                    Button("检查连接") { model.diagnose() }.disabled(model.busy || model.diagnosticBusy)
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
                Button("导出 Clash 脚本…") { model.revealScript() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.busy ? "正在处理，请稍候" : model.dirty ? "有待保存的配置" : "配置保存于用户目录 · 按需连接")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存配置") { model.save() }.disabled(model.busy).keyboardShortcut("s", modifiers: .command)
                Button(model.ownsSession ? "停止连接" : model.legacyInstalled ? "迁移并启动" : "启动连接") {
                    if model.ownsSession { model.stop() } else { model.start() }
                }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.05, green: 0.46, blue: 0.44))
                    .disabled(model.busy || model.coordinating)
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
        Button("打开控制面板") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.ownsSession { Button("停止连接") { model.stop() }.disabled(model.busy || model.coordinating) }
        else { Button("启动连接") { model.start() }.disabled(model.busy || model.coordinating) }
        Divider()
        Button("退出并停止连接") { model.stop(quit: true) }.disabled(model.busy || model.coordinating)
    }
}

final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.setActivationPolicy(.accessory)
        return false
    }
}

struct TetherApp: App {
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var appDelegate
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
            model.refresh(coordinate: false)
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
            let root = appResourcesDirectory()
            let ok = ["rndis-tether", "rndis-tether-gui-helper"].allSatisfy { FileManager.default.isExecutableFile(atPath: root + "/" + $0) }
            print(ok ? "App resources OK" : "App resources missing")
            exit(ok ? 0 : 1)
        }
        TetherApp.main()
    }
}
