import Foundation
import Darwin

struct ClashSelection: Codable {
    let owner: Int32
    let previous: String
}

struct ClashControl {
    static let group = "RNDIS Tether"
    static let usb = "RNDIS Tether USB"
    private let endpoint: String
    private let secret: String
    private let journal: URL

    init(endpoint: String, secret: String = "", journal: URL = UserFiles.journal) throws {
        guard endpoint.hasPrefix("/"), endpoint.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              secret.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else { throw TetherError("Clash 控制接口参数无效。") }
        self.endpoint = endpoint
        self.secret = secret
        self.journal = journal
    }

    static func discover() throws -> ClashControl {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
        let text = (try? String(contentsOf: folder.appendingPathComponent("clash-verge.yaml"), encoding: .utf8)) ?? ""
        func scalar(_ key: String) -> String {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") }) else { return "" }
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
            if value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            return value
        }
        let candidates = ["/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock", scalar("external-controller-unix")]
        guard let socket = candidates.first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) else {
            throw TetherError("未检测到 Clash Verge 控制接口。请启动 Clash Verge，并启用其控制接口。")
        }
        return try ClashControl(endpoint: socket, secret: scalar("secret"))
    }

    func request(_ method: String, path: String, object: [String: String]? = nil) throws -> [String: Any] {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TetherError("无法连接 Clash。") }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(endpoint.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TetherError("Clash 控制接口路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw TetherError("Clash 控制接口不可用，请检查 Clash Verge 是否运行。") }
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let auth = secret.isEmpty ? "" : "Authorization: Bearer \(secret)\r\n"
        let header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n\(auth)Content-Length: \(body.count)\r\n\r\n"
        var outgoing = Data(header.utf8); outgoing.append(body)
        try outgoing.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw TetherError("向 Clash 发送请求失败。") }
                offset += sent
            }
        }
        var incoming = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw TetherError("等待 Clash 响应超时。") }
            if count == 0 { break }
            incoming.append(contentsOf: buffer.prefix(count))
            guard incoming.count <= 1_048_576 else { throw TetherError("Clash 响应过大。") }
        }
        return try Self.decodeResponse(incoming)
    }

    static func decodeResponse(_ data: Data) throws -> [String: Any] {
        guard let divider = data.range(of: Data("\r\n\r\n".utf8)) else { throw TetherError("Clash 响应格式错误。") }
        let header = String(decoding: data[..<divider.lowerBound], as: UTF8.self)
        let fields = header.split(separator: "\n").first?.split(separator: " ") ?? []
        guard fields.count >= 2, let status = Int(fields[1]) else { throw TetherError("Clash 响应状态错误。") }
        guard (200..<300).contains(status) else {
            throw TetherError(status == 404 ? "请先在 Clash Verge 中启用导出的脚本，创建 RNDIS Tether 分流组。" : "Clash 返回 HTTP \(status)。")
        }
        var body = Data(data[divider.upperBound...])
        if header.lowercased().contains("transfer-encoding: chunked") {
            var decoded = Data()
            while true {
                guard let end = body.range(of: Data("\r\n".utf8)),
                      let line = String(data: body[..<end.lowerBound], encoding: .utf8),
                      let size = line.split(separator: ";").first,
                      let length = Int(size, radix: 16), length >= 0 else { throw TetherError("Clash 分块响应无效。") }
                body.removeSubrange(..<end.upperBound)
                if length == 0 { body = decoded; break }
                guard length <= body.count, body.count - length >= 2,
                      body.dropFirst(length).prefix(2) == Data("\r\n".utf8) else { throw TetherError("Clash 分块响应不完整。") }
                decoded.append(body.prefix(length)); body.removeFirst(length + 2)
            }
        }
        if body.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw TetherError("Clash 响应格式错误。") }
        return object
    }

    private var groupPath: String { "/proxies/RNDIS%20Tether" }

    func selection() throws -> String {
        let value = try request("GET", path: groupPath)
        guard value["type"] as? String == "Selector", let all = value["all"] as? [String],
              all.contains(Self.usb), all.contains("DIRECT"), let current = value["now"] as? String else {
            throw TetherError("Clash 中存在同名分流组，请检查导入的 RNDIS Tether 脚本。")
        }
        return current
    }

    func select(_ name: String) throws {
        _ = try request("PUT", path: groupPath, object: ["name": name])
    }

    func enableUSB(owner: Int32) throws {
        let previous = try selection()
        if FileManager.default.fileExists(atPath: journal.path) {
            let saved = try JSONDecoder().decode(ClashSelection.self, from: Data(contentsOf: journal))
            guard saved.owner == owner else { throw TetherError("另一个连接尚未恢复 Clash 分流组。") }
        } else {
            let saved = previous == Self.usb ? "DIRECT" : previous
            // Save recovery intent before changing external state.
            try UserFiles.save(JSONEncoder().encode(ClashSelection(owner: owner, previous: saved)), to: journal)
        }
        do { try select(Self.usb) }
        catch { try? restore(owner: owner); throw error }
    }

    static func restore(owner: Int32? = nil) throws {
        guard FileManager.default.fileExists(atPath: UserFiles.journal.path) else { return }
        try discover().restore(owner: owner)
    }

    func restore(owner: Int32? = nil) throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let data = try Data(contentsOf: journal)
        let saved = try JSONDecoder().decode(ClashSelection.self, from: data)
        if let owner = owner, saved.owner != owner { return }
        if try selection() == Self.usb { try select(saved.previous) }
        try FileManager.default.removeItem(at: journal)
    }
}
