import Foundation
import Darwin

struct RoutingTarget {
    let normalized: String
    let domain: String?
    private let condition: String
    private let port: String?

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var target = text
        var portText: String?
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]") else { throw TetherError("IPv6 目标的方括号不完整。") }
            target = String(text[text.index(after: text.startIndex)..<closing])
            guard target.contains(":") else { throw TetherError("方括号用于 IPv6 地址或网段。") }
            let suffix = text[text.index(after: closing)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw TetherError("IPv6 端口请写为 [地址或网段]:端口。") }
                portText = String(suffix.dropFirst())
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            target = String(text[..<colon])
            portText = String(text[text.index(after: colon)...])
        }
        port = try portText.map(Self.parsePort)

        guard !target.isEmpty, target.utf8.allSatisfy({ $0 > 32 && $0 != 127 && $0 != 37 }) else {
            throw TetherError("目标不能包含空白、控制字符或 % 作用域。")
        }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { throw TetherError("CIDR 目标只能包含一个前缀长度。") }
        var address4 = in_addr()
        var address6 = in6_addr()
        var bytes: [UInt8]
        let family: Int32
        let maximumPrefix: Int
        if inet_pton(AF_INET, parts[0], &address4) == 1 {
            bytes = withUnsafeBytes(of: address4) { Array($0) }
            family = AF_INET
            maximumPrefix = 32
        } else if inet_pton(AF_INET6, parts[0], &address6) == 1 {
            bytes = withUnsafeBytes(of: address6) { Array($0) }
            family = AF_INET6
            maximumPrefix = 128
        } else {
            guard parts.count == 1, validHostname(target),
                  !target.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
                throw TetherError("目标应为域名、IPv4、IPv6 或 CIDR，可附加端口。IPv6 端口使用 [地址/前缀]:端口。")
            }
            domain = target
            condition = "DOMAIN-SUFFIX," + target
            normalized = target + (port.map { ":" + $0 } ?? "")
            return
        }
        let prefix = try parts.count == 2 ? Self.number(parts[1], range: 0...maximumPrefix, name: "CIDR 前缀") : maximumPrefix
        for index in bytes.indices {
            let remaining = prefix - index * 8
            if remaining <= 0 { bytes[index] = 0 }
            else if remaining < 8 { bytes[index] &= UInt8.max << (8 - remaining) }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard bytes.withUnsafeBytes({ inet_ntop(family, $0.baseAddress!, &buffer, socklen_t(buffer.count)) }) != nil else {
            throw TetherError("无法规范化 IP 地址。")
        }
        let address = String(cString: buffer)
        let network = address + "/" + String(prefix)
        domain = nil
        condition = (family == AF_INET ? "IP-CIDR," : "IP-CIDR6,") + network
        let display = parts.count == 2 ? network : address
        if let port = port {
            normalized = (family == AF_INET6 ? "[" + display + "]" : display) + ":" + port
        } else { normalized = display }
    }

    func clashRule(group: String) -> String {
        if let port = port { return "AND,((\(condition)),(DST-PORT,\(port))),\(group)" }
        return condition + "," + group
    }

    private static func number(_ text: String, range: ClosedRange<Int>, name: String) throws -> Int {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), range.contains(value) else {
            throw TetherError("\(name)应为 \(range.lowerBound)–\(range.upperBound) 之间的整数。")
        }
        return value
    }

    private static func parsePort(_ text: String) throws -> String {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { throw TetherError("端口支持单值或范围，例如 443、8000-8100。") }
        let first = try number(parts[0], range: 1...65535, name: "端口")
        if parts.count == 1 { return String(first) }
        let last = try number(parts[1], range: first...65535, name: "范围结束端口")
        return first == last ? String(first) : "\(first)-\(last)"
    }
}
