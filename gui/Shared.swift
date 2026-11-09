import Foundation
import Darwin

enum LegacyPaths {
    static let daemon = "/Library/PrivilegedHelperTools/io.github.stlk0.rndis-tether"
    static let helper = "/Library/PrivilegedHelperTools/rndis-tether-gui-helper"
    static let config = "/etc/rndis-tether-gui.json"
    static let daemonConfig = "/etc/rndis-tether.conf"
    static let stateDir = "/var/db/rndis-tether-gui"
    static let state = stateDir + "/routes.json"
}

func appResourcesDirectory() -> String {
    // Bundle caches its original URL even when Finder moves a running .app.
    // The kernel tracks the executable's current vnode location instead.
    var executablePath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(getpid(), &executablePath, UInt32(executablePath.count)) > 0 {
        let executable = URL(fileURLWithPath: String(cString: executablePath))
        let directory = executable.deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" {
            return contents.appendingPathComponent("Resources").path
        }
    }
    return Bundle.main.resourceURL!.path
}

struct TetherError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

func ipv6(_ text: String, routable: Bool = true) -> String? {
    var raw = in6_addr()
    guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
    let bytes = withUnsafeBytes(of: raw) { Array($0) }
    if routable && (bytes.allSatisfy { $0 == 0 } ||
        (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1) ||
        bytes[0] == 0xff || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) ||
        (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)) {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
    return String(cString: buffer)
}

func validHostname(_ text: String) -> Bool {
    guard text.utf8.count <= 253, !text.isEmpty else { return false }
    return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
        $0.count <= 63 && matches(String($0), "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
    }
}

struct CommandResult {
    var code: Int32
    var text: String
}

// Call off the UI thread. The deadline also bounds hung diagnostic subprocesses.
func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> CommandResult {
    if ["rndis-tether-gui-helper", "rndis-tether"].contains(URL(fileURLWithPath: path).lastPathComponent),
       !FileManager.default.isExecutableFile(atPath: path) {
        throw TetherError("无法执行应用资源：\(path)\n请退出前端，再从安装位置重新打开完整的 RNDIS Tether.app。")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let timeoutWork = DispatchWorkItem {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeoutWork.cancel()
    return CommandResult(code: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
}

@discardableResult
func checked(_ path: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> String {
    let result = try command(path, arguments, timeout: timeout)
    guard result.code == 0 else { throw TetherError("\(URL(fileURLWithPath: path).lastPathComponent)：\(result.text.trimmingCharacters(in: .whitespacesAndNewlines))") }
    return result.text
}

func fields(_ text: String, separator: Character = "=") -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let pair = line.split(separator: separator, maxSplits: 1)
        if pair.count == 2 {
            result[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
    }
    return result
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func appleScriptLiteral(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
}
