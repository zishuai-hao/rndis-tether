import Foundation
import Darwin

struct Hop: Codable, Equatable {
    var interface: String
    var gateway: String
}

struct DNSCache: Codable {
    var addresses: [String]
    var expires: TimeInterval
}

struct RouteState: Codable {
    var gateway: String?
    var owned: [String: Hop] = [:]
    var cache: [String: DNSCache] = [:]
}

protocol RouteSystem {
    func gateway(_ interface: String) throws -> String?
    func resolve(_ target: String) throws -> [String]
    func route(_ address: String) throws -> Hop?
    func set(_ address: String, hop: Hop, replacing: Bool) throws
    func delete(_ address: String, hop: Hop) throws
}

func parseGateway(_ table: String, interface: String) -> String? {
    for line in table.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 4, parts[0] == "default", parts[3] == interface else { continue }
        let address = String(parts[1].split(separator: "%")[0])
        if let canonical = ipv6(address, routable: false), canonical.hasPrefix("fe80:") {
            return canonical + "%" + interface
        }
    }
    return nil
}

func parseRoute(_ text: String, address: String) -> Hop? {
    let values = fields(text, separator: ":")
    guard values["flags"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).split(separator: ",").contains("HOST") == true,
          ipv6(values["destination"] ?? "") == address,
          let interface = values["interface"], var gateway = values["gateway"] else { return nil }
    if gateway.hasPrefix("fe80:") && !gateway.contains("%") { gateway += "%" + interface }
    return Hop(interface: interface, gateway: gateway)
}

struct MacRouteSystem: RouteSystem {
    func gateway(_ interface: String) throws -> String? {
        let output = try command("/sbin/ifconfig", [interface])
        guard output.code == 0 else { return nil }
        let ready = output.text.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            return parts.count >= 2 && parts[0] == "inet6" && ipv6(String(parts[1].split(separator: "%")[0])) != nil
        }
        guard ready else { return nil }
        return parseGateway(try checked("/usr/sbin/netstat", ["-rn", "-f", "inet6"]), interface: interface)
    }

    func resolve(_ target: String) throws -> [String] {
        if let address = ipv6(target) { return [address] }
        // getaddrinfo itself has no portable per-call deadline. Isolate it in a
        // short-lived child so eight failing targets fit the daemon's 30s budget.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        let result = try command(executable, ["resolve", target], timeout: 2.5)
        guard result.code == 0 else { throw TetherError("\(target) 的 AAAA 查询失败或超时。") }
        let addresses = result.text.split(separator: "\n").compactMap { ipv6(String($0)) }
        guard !addresses.isEmpty else { throw TetherError("\(target) 未解析到可路由的 IPv6 地址。") }
        return Array(Set(addresses)).sorted()
    }

    func route(_ address: String) throws -> Hop? {
        parseRoute(try command("/sbin/route", ["-n", "get", "-inet6", address]).text, address: address)
    }

    func set(_ address: String, hop: Hop, replacing: Bool) throws {
        try checked("/sbin/route", ["-n", replacing ? "change" : "add", "-inet6", "-host", address, hop.gateway])
    }

    func delete(_ address: String, hop: Hop) throws {
        try checked("/sbin/route", ["-n", "delete", "-inet6", "-host", address, hop.gateway])
    }
}

func resolveAddresses(_ target: String) throws -> [String] {
        if let address = ipv6(target) { return [address] }
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let error = getaddrinfo(target, nil, &hints, &list)
        guard error == 0 else { throw TetherError("\(target) 的 AAAA 查询失败：\(String(cString: gai_strerror(error)))") }
        defer { if let list = list { freeaddrinfo(list) } }
        var found = Set<String>()
        var next = list
        while let item = next {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
               let value = ipv6(String(cString: host)) { found.insert(value) }
            next = item.pointee.ai_next
        }
        guard !found.isEmpty else { throw TetherError("\(target) 未解析到可路由的 IPv6 地址。") }
        return Array(found.sorted().prefix(32))
}

// Owned entries are updated after each successful mutation so a later failure can
// persist the exact partial result. A successful empty DNS response is conservative.
func reconcile(_ state: inout RouteState, interface: String, targets: [String], system: RouteSystem,
               now: TimeInterval, forceDNS: Bool = false,
               checkpoint: ((RouteState) throws -> Void)? = nil) throws -> [String] {
    let gateway = try system.gateway(interface)
    var desired = Set<String>()
    var messages: [String] = []
    if let gateway = gateway, !targets.isEmpty {
        for target in targets {
            var entry = state.cache[target] ?? DNSCache(addresses: [], expires: 0)
            if forceDNS || entry.expires <= now || state.gateway != gateway {
                do {
                    entry = DNSCache(addresses: try system.resolve(target), expires: now + 300)
                } catch {
                    entry.expires = now + 60
                    messages.append(error.localizedDescription + " 已保留上次成功解析的地址。")
                }
                state.cache[target] = entry
            }
            desired.formUnion(entry.addresses)
        }
        let expected = Hop(interface: interface, gateway: gateway)
        for address in desired.sorted() {
            let current = try system.route(address)
            if current != expected {
                try system.set(address, hop: expected, replacing: current != nil)
                messages.append("\(address)/128 → \(gateway)")
            }
            // Do not adopt a matching route created by another administrator.
            if current != expected || state.owned[address] == expected {
                state.owned[address] = expected
                try checkpoint?(state)
            }
        }
    }
    for address in state.owned.keys.sorted() where !desired.contains(address) {
        if let previous = state.owned[address], try system.route(address) == previous {
            try system.delete(address, hop: previous)
        }
        state.owned.removeValue(forKey: address)
        try checkpoint?(state)
    }
    state.gateway = gateway
    state.cache = state.cache.filter { targets.contains($0.key) }
    return messages
}
