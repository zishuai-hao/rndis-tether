import Foundation
import Darwin

private let fileManager = FileManager.default

private func trustedDirectory(_ path: String, create: Bool = false, mode: mode_t = 0o755) throws {
    if create && !fileManager.fileExists(atPath: path) {
        guard mkdir(path, mode) == 0 else { throw TetherError("无法创建 \(path)：\(String(cString: strerror(errno)))") }
    }
    var current = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    while true {
        var info = stat()
        guard lstat(current, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw TetherError("系统目录权限不安全：\(current)") }
        if current == "/" { return }
        current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }
}

private func checkFile(_ path: String) throws {
    var info = stat()
    if lstat(path, &info) != 0 {
        if errno == ENOENT { return }
        throw TetherError("无法检查 \(path)")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_mode & 0o022 == 0,
          info.st_size <= 2_000_000 else { throw TetherError("文件必须是 root 所有的普通文件，且不可由其他用户修改：\(path)") }
}

private func atomicWrite(_ data: Data, path: String, mode: mode_t = 0o644) throws {
    try trustedDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    try checkFile(path)
    // mkstemp in the trusted destination directory; never follow a .new symlink.
    var template = Array((path + ".XXXXXX").utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { throw TetherError("无法暂存 \(path)") }
    let temporary = String(cString: template)
    defer { close(descriptor); unlink(temporary) }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TetherError("写入失败：\(path)") }
            offset += count
        }
    }
    guard fchmod(descriptor, mode) == 0, fchown(descriptor, 0, 0) == 0, fsync(descriptor) == 0,
          rename(temporary, path) == 0 else { throw TetherError("无法保存 \(path)") }
}

private func rootRequired() throws {
    guard geteuid() == 0 else { throw TetherError("此操作需要管理员授权。") }
}

private func withLock(_ operation: () throws -> Void) throws {
    try rootRequired()
    try trustedDirectory(Paths.stateDir, create: true, mode: 0o700)
    let descriptor = open(Paths.stateDir + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw TetherError("无法打开路由策略锁。") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o077 == 0 else { throw TetherError("路由策略锁权限不安全。") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        // The daemon will retry a coalesced event; an interactive action must report busy.
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1].hasPrefix("feth") { return }
        throw TetherError("另一个配置或路由更新正在执行，请稍后重试。")
    }
    defer { flock(descriptor, LOCK_UN) }
    try operation()
}

private func loadState() throws -> RouteState {
    try checkFile(Paths.state)
    guard let data = fileManager.contents(atPath: Paths.state) else { return RouteState() }
    return try JSONDecoder().decode(RouteState.self, from: data)
}

private func updateRoutes(_ config: GUIConfig, interface: String, clear: Bool = false) throws {
    var state = try loadState()
    let persist = { try atomicWrite(JSONEncoder().encode(state), path: Paths.state, mode: 0o600) }
    do {
        let messages = try reconcile(&state, interface: interface,
            targets: !clear && config.enabled ? config.targets : [], system: MacRouteSystem(),
            now: Date().timeIntervalSince1970,
            forceDNS: ProcessInfo.processInfo.environment["RNDIS_TETHER_EVENT"] == "refresh",
            checkpoint: { try atomicWrite(JSONEncoder().encode($0), path: Paths.state, mode: 0o600) })
        try persist()
        for message in messages { FileHandle.standardError.write(Data(("rndis GUI route: " + message + "\n").utf8)) }
    } catch {
        try persist()
        throw error
    }
}

private func daemonSettings() throws -> [String: String] {
    var values: [String: String] = [:]
    guard let data = fileManager.contents(atPath: Paths.daemonConfig) else { return values }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let value = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pair = value.split(separator: "=", maxSplits: 1)
        if value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard pair.count == 2 else { throw TetherError("现有 rndis-tether.conf 包含无效配置，请先修复。") }
        values[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces)
    }
    return values
}

private func managedResolvers(_ config: GUIConfig?) -> [String] {
    guard let config = config, config.enabled, !config.dnsServer.isEmpty else { return [] }
    return config.targets.filter { ipv6($0) == nil && validHostname($0) }.map { "/etc/resolver/" + $0 }
}

private struct Backup {
    var path: String
    var data: Data?
    var mode: mode_t
    init(_ path: String) throws {
        self.path = path
        try checkFile(path)
        var info = stat()
        mode = lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0o644
        data = fileManager.contents(atPath: path)
    }
    func restore() throws {
        if let data = data { try atomicWrite(data, path: path, mode: mode) }
        else if fileManager.fileExists(atPath: path) { try fileManager.removeItem(atPath: path) }
    }
}

private func install(resources: String, config: GUIConfig) throws {
    try withLock {
        let bundleCLI = resources + "/rndis-tether"
        let bundleHelper = resources + "/rndis-tether-gui-helper"
        guard fileManager.isExecutableFile(atPath: bundleCLI), fileManager.isExecutableFile(atPath: bundleHelper) else {
            throw TetherError("应用资源不完整，请重新解压完整的 .app。")
        }
        try trustedDirectory("/Library/PrivilegedHelperTools", create: true)
        let oldConfig = GUIConfig.load()
        if fileManager.fileExists(atPath: Paths.config) && oldConfig == nil { throw TetherError("现有 GUI 配置无法读取，未覆盖。") }
        let newResolvers = managedResolvers(config)
        let allResolvers = Array(Set(managedResolvers(oldConfig) + newResolvers))
        if !allResolvers.isEmpty { try trustedDirectory("/etc/resolver", create: true) }
        // A domain-specific resolver is explicitly opt-in. Never overwrite a resolver
        // managed by a VPN, the administrator, or the earlier command-line example.
        for path in allResolvers {
            try checkFile(path)
            if let data = fileManager.contents(atPath: path),
               !String(decoding: data, as: UTF8.self).hasPrefix(Paths.resolverMarker) {
                throw TetherError("\(path) 已由其他配置管理。请留空专用 DNS，或先自行迁移该文件。")
            }
        }
        var settings = try daemonSettings()
        let interface = settings["host-interface"] ?? "feth50"
        guard matches(interface, "^feth[0-9]{1,10}$") else { throw TetherError("现有 host-interface 无效。") }
        let paths = [Paths.config, Paths.daemonConfig, Paths.helper, Paths.daemon,
            "/Library/LaunchDaemons/io.github.stlk0.rndis-tether.plist"] + allResolvers
        let backups = try paths.map(Backup.init)
        do {
            if let oldConfig = oldConfig { try updateRoutes(oldConfig, interface: interface, clear: true) }
            try atomicWrite(Data(contentsOf: URL(fileURLWithPath: bundleHelper)), path: Paths.helper, mode: 0o755)
            try atomicWrite(config.encoded(), path: Paths.config)
            for path in allResolvers {
                if newResolvers.contains(path) {
                    try atomicWrite(Data((Paths.resolverMarker + "nameserver \(config.dnsServer)\n").utf8), path: path)
                } else { try fileManager.removeItem(atPath: path) }
            }
            settings["prefer-phone"] = config.preferPhone ? "yes" : "no"
            settings["ipv6"] = "yes"
            settings["network-hook"] = config.enabled ? Paths.helper : "none"
            let text = settings.keys.sorted().map { "\($0) = \(settings[$0]!)" }.joined(separator: "\n") + "\n"
            try atomicWrite(Data(text.utf8), path: Paths.daemonConfig)
            // The existing installer provides the launchd job and root-owned daemon.
            // Invoke once after all settings are ready, avoiding three restarts.
            _ = try checked(bundleCLI, ["install"], timeout: 45)
        } catch {
            let original = error
            _ = try? command("/bin/launchctl", ["bootout", "system/io.github.stlk0.rndis-tether"])
            var failures: [String] = []
            for backup in backups {
                do { try backup.restore() } catch { failures.append(backup.path) }
            }
            if fileManager.isExecutableFile(atPath: Paths.daemon) {
                do { _ = try checked(Paths.daemon, ["install"], timeout: 45) }
                catch { failures.append("后台服务重新启动") }
            }
            throw TetherError(original.localizedDescription + (failures.isEmpty ? "\n已恢复原有配置。" : "\n部分恢复失败：" + failures.joined(separator: ", ")))
        }
        print("后台服务和路由配置已保存。手机重连后会自动更新路由。")
    }
}

private func uninstall() throws {
    try withLock {
        if let config = GUIConfig.load() {
            let interface = try daemonSettings()["host-interface"] ?? "feth50"
            try updateRoutes(config, interface: interface, clear: true)
            for path in managedResolvers(config) {
                if let data = fileManager.contents(atPath: path), String(decoding: data, as: UTF8.self).hasPrefix(Paths.resolverMarker) {
                    try fileManager.removeItem(atPath: path)
                }
            }
        }
        if fileManager.isExecutableFile(atPath: Paths.daemon) { _ = try checked(Paths.daemon, ["uninstall"], timeout: 45) }
        for path in [Paths.config, Paths.helper, Paths.state] {
            try checkFile(path)
            if fileManager.fileExists(atPath: path) { try fileManager.removeItem(atPath: path) }
        }
        print("已卸载后台服务，并清理 GUI 管理的路由与 DNS 配置。")
    }
}

private func diagnose(_ config: GUIConfig, interface: String) throws {
    let system = MacRouteSystem()
    let gateway = try system.gateway(interface)
    print("USB 接口：\(interface)")
    print("手机 IPv6 网关：\(gateway ?? "未就绪；请保持移动数据开启、手机 Wi-Fi 关闭，并开启 USB 网络共享。")")
    print("DNS：\(config.dnsServer.isEmpty ? "系统 DNS" : config.dnsServer + "（需保存配置后生效）")")
    for target in config.targets {
        print("\n目标：\(target)")
        do {
            for address in try system.resolve(target) {
                let hop = try system.route(address)
                if let hop = hop { print("  \(address)  →  \(hop.interface) / \(hop.gateway)") }
                else { print("  \(address)  →  当前无独立 /128 路由") }
            }
        } catch { print("  " + error.localizedDescription + " 可配置专用 DNS 或使用 IPv6 地址。") }
    }
    print("\n诊断为只读检查，不会修改路由；HTTPS 可用性还取决于服务器和防火墙。")
}

@main
struct HelperMain {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 3 && args[0] == "install" {
                guard let data = Data(base64Encoded: args[2]) else { throw TetherError("配置编码无效。") }
                try install(resources: args[1], config: JSONDecoder().decode(GUIConfig.self, from: data).validated())
            } else if args.count == 2 && args[0] == "resolve" && (validHostname(args[1]) || ipv6(args[1]) != nil) {
                print(try resolveAddresses(args[1]).joined(separator: "\n"))
            } else if args == ["uninstall"] {
                try uninstall()
            } else if args.count == 3 && args[0] == "diagnose" && matches(args[2], "^feth[0-9]{1,10}$") {
                guard let data = Data(base64Encoded: args[1]) else { throw TetherError("配置编码无效。") }
                try diagnose(JSONDecoder().decode(GUIConfig.self, from: data).validated(), interface: args[2])
            } else if args.count == 1 && matches(args[0], "^feth[0-9]{1,10}$") {
                try withLock {
                    try checkFile(Paths.config)
                    guard let config = GUIConfig.load() else { throw TetherError("无法读取路由配置。") }
                    try updateRoutes(config.validated(), interface: args[0])
                }
            } else {
                throw TetherError("Usage: rndis-tether-gui-helper fethN | install RESOURCES BASE64_CONFIG | uninstall | diagnose BASE64_CONFIG fethN")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
