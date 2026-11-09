import Foundation
import Darwin

private let fileManager = FileManager.default
private let runtimeDirectory = "/var/db/rndis-tether"
private let backupPath = runtimeDirectory + "/legacy-backup.json"
private let resolverMarker = "# Managed by RNDIS Tether GUI\n"

private func rootRequired() throws {
    guard geteuid() == 0 else { throw TetherError("此操作需要管理员授权。") }
}

private func checkedSystemFile(_ path: String) throws {
    var info = stat()
    if lstat(path, &info) != 0 {
        if errno == ENOENT { return }
        throw TetherError("无法检查系统文件：\(path)")
    }
    guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o022 == 0, info.st_size <= 4_000_000 else {
        throw TetherError("系统文件权限或类型不安全：\(path)")
    }
}

private func writeSystemFile(_ data: Data, path: String, mode: mode_t) throws {
    try trustedDirectory((path as NSString).deletingLastPathComponent)
    try checkedSystemFile(path)
    var name = Array((path + ".XXXXXX").utf8CString)
    let descriptor = mkstemp(&name)
    guard descriptor >= 0 else { throw TetherError("无法创建系统文件暂存。") }
    let temporary = String(cString: name)
    defer { close(descriptor); unlink(temporary) }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TetherError("系统文件写入失败。") }
            offset += count
        }
    }
    guard fchmod(descriptor, mode) == 0, fchown(descriptor, 0, 0) == 0,
          fsync(descriptor) == 0, rename(temporary, path) == 0 else { throw TetherError("系统文件保存失败。") }
}

private func withMigrationLock(_ action: () throws -> Void) throws {
    try rootRequired()
    try trustedDirectory(runtimeDirectory, create: true, mode: 0o700)
    let descriptor = open(runtimeDirectory + "/on-demand.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw TetherError("无法创建按需连接锁。") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o077 == 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw TetherError("另一个连接或迁移操作正在进行。")
    }
    defer { flock(descriptor, LOCK_UN) }
    try action()
}

private let oldFiles = [LegacyPaths.config, LegacyPaths.daemonConfig, LegacyPaths.helper,
                        LegacyPaths.daemon, LegacyPaths.state,
                        "/Library/LaunchDaemons/io.github.stlk0.rndis-tether.plist"]

private struct SystemBackup: Codable {
    let path: String
    let data: Data?
    let mode: mode_t

    init(_ path: String) throws {
        try checkedSystemFile(path)
        self.path = path
        var info = stat()
        mode = lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0o644
        data = fileManager.contents(atPath: path)
    }

    func restore() throws {
        if let data = data { try writeSystemFile(data, path: path, mode: mode) }
        else if fileManager.fileExists(atPath: path) { try checkedSystemFile(path); try fileManager.removeItem(atPath: path) }
    }
}

private func ownedResolvers() throws -> [String] {
    guard fileManager.fileExists(atPath: "/etc/resolver") else { return [] }
    try trustedDirectory("/etc/resolver")
    return try fileManager.contentsOfDirectory(atPath: "/etc/resolver").compactMap { name in
        guard validHostname(name) else { return nil }
        let path = "/etc/resolver/" + name
        guard (try? checkedSystemFile(path)) != nil,
              let data = fileManager.contents(atPath: path),
              String(decoding: data, as: UTF8.self).hasPrefix(resolverMarker) else { return nil }
        return path
    }
}

private func waitForStop(cli: String) throws {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if fields(try command(cli, ["status", "--raw"]).text)["protocol"] == nil { return }
        usleep(100_000)
    }
    throw TetherError("USB 后台尚未停止，请稍后重试。")
}

private func startDemand(resources: String, owner: Int32) throws {
    try withMigrationLock {
        guard owner > 1, kill(owner, 0) == 0 else { throw TetherError("前端进程已退出。") }
        let cli = resources + "/rndis-tether"
        guard fileManager.isExecutableFile(atPath: cli) else { throw TetherError("应用缺少 USB 后台程序。") }
        let status = fields(try command(cli, ["status", "--raw"]).text)
        if let activeOwner = status["owner-pid"] {
            guard activeOwner == String(owner) else { throw TetherError("另一个前端已启动连接，请先退出该前端。") }
            print("按需连接已运行。")
            return
        }
        let hasLegacy = oldFiles.contains { fileManager.fileExists(atPath: $0) }
        if status["protocol"] != nil && !hasLegacy { throw TetherError("已有手工启动的 USB 后台，请先结束它。") }
        let resolvers = try ownedResolvers()
        let backups = try (oldFiles + resolvers).map(SystemBackup.init)
        let child = Process()
        do {
            if hasLegacy || !resolvers.isEmpty {
                try writeSystemFile(JSONEncoder().encode(backups), path: backupPath, mode: 0o600)
                _ = try checked(cli, ["uninstall"], timeout: 45)
                try waitForStop(cli: cli)
                for path in [LegacyPaths.config, LegacyPaths.helper, LegacyPaths.state] + resolvers {
                    try checkedSystemFile(path)
                    if fileManager.fileExists(atPath: path) { try fileManager.removeItem(atPath: path) }
                }
            }
            child.executableURL = URL(fileURLWithPath: cli)
            child.arguments = ["run-on-demand", String(owner)]
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard child.isRunning else { throw TetherError("按需 USB 后台启动失败。") }
                if fields(try command(cli, ["status", "--raw"]).text)["owner-pid"] == String(owner) {
                    print("按需 USB 连接已启动，退出前端后自动停止。")
                    if hasLegacy { print("旧版配置备份：\(backupPath)") }
                    return
                }
                usleep(100_000)
            }
            throw TetherError("等待按需 USB 后台超时。")
        } catch {
            if child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(8)
                while child.isRunning && Date() < deadline { usleep(100_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            }
            var failures: [String] = []
            for backup in backups {
                do { try backup.restore() } catch { failures.append(backup.path) }
            }
            if status["protocol"] != nil && fileManager.isExecutableFile(atPath: LegacyPaths.daemon) {
                do {
                    _ = try checked(LegacyPaths.daemon, ["install"], timeout: 45)
                    if status["paused"] == "yes" { _ = try checked(LegacyPaths.daemon, ["disconnect"]) }
                }
                catch { failures.append("旧版后台重新启动") }
            }
            throw TetherError(error.localizedDescription + (failures.isEmpty ? " 已恢复迁移前配置。" : " 部分恢复失败：" + failures.joined(separator: ", ")))
        }
    }
}

private func restoreLegacy(resources: String) throws {
    try withMigrationLock {
        try checkedSystemFile(backupPath)
        let backups = try JSONDecoder().decode([SystemBackup].self, from: Data(contentsOf: URL(fileURLWithPath: backupPath)))
        guard backups.count <= 64, backups.allSatisfy({ entry in
            oldFiles.contains(entry.path) || (entry.path.hasPrefix("/etc/resolver/") && validHostname(String(entry.path.dropFirst("/etc/resolver/".count))))
        }) else { throw TetherError("迁移备份路径无效。") }
        let cli = resources + "/rndis-tether"
        _ = try checked(cli, ["stop-on-demand"])
        try waitForStop(cli: cli)
        for backup in backups { try backup.restore() }
        if fileManager.isExecutableFile(atPath: LegacyPaths.daemon) {
            _ = try checked(LegacyPaths.daemon, ["install"], timeout: 45)
        }
        print("迁移前的系统配置已恢复。")
    }
}

@main
struct HelperMain {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["check-system-paths"] {
                try checkSystemDirectories()
                print("系统目录检查通过（只读）。")
            } else if args.count == 3, args[0] == "start-demand", let owner = Int32(args[2]) {
                try startDemand(resources: args[1], owner: owner)
            } else if args.count == 2, args[0] == "restore-legacy" {
                try restoreLegacy(resources: args[1])
            } else if args.count == 2, args[0] == "watch-demand", let owner = Int32(args[1]), owner > 1, getuid() != 0 {
                while getppid() == owner { sleep(1) }
                for attempt in 0..<20 {
                    do { try ClashControl.restore(owner: owner); break }
                    catch { if attempt < 19 { sleep(3) } }
                }
            } else if (args.count == 2 || (args.count == 3 && args[2] == "--https")),
                      args[0] == "diagnose-demand", matches(args[1], "^feth[0-9]{1,10}$") {
                let interface = args[1]
                let gateway = try phoneIPv6Gateway(interface)
                let status = fields(try command(appResourcesDirectory() + "/rndis-tether", ["status", "--raw"]).text)
                var ready = status["state"] == "online" && status["interface"] == interface
                print("USB 接口：\(interface)\n手机 IPv4：\(status["address"] ?? "未就绪")\n手机 IPv6 网关：\(gateway ?? "未就绪")")
                if !DemandPreferences.load().targets.isEmpty {
                    do {
                        let selection = try ClashControl.discover().selection()
                        print("Clash 分流组：\(selection)")
                        if selection != ClashControl.usb { ready = false }
                    } catch { ready = false; print(error.localizedDescription) }
                } else {
                    print("Clash 分流：尚未配置目标")
                }
                if args.count == 3 {
                    let families: [ProbeIPFamily] = gateway == nil ? [.ipv4] : [.ipv4, .ipv6]
                    var passed = false
                    for family in families {
                        let probes = publicHTTPSProbes(interface: interface, family: family)
                        for probe in probes { print("\(family.label) https://\(probe.host)/：\(probe.passed ? "通过" : "未通过")\n\(probe.detail)") }
                        passed = passed || probes.contains { $0.passed }
                    }
                    ready = ready && passed
                }
                print("结果：\(ready ? "手机与 Clash 分流检查通过" : "尚未通过，请检查以上项目")。")
                print("用户配置：\(UserFiles.settings.path)\nClash 脚本：\(UserFiles.clashScript.path)")
                if !ready { exit(2) }
            } else {
                throw TetherError("Usage: helper start-demand RESOURCES OWNER_PID | restore-legacy RESOURCES | watch-demand OWNER_PID | diagnose-demand fethN [--https]")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
