import Foundation
import Darwin

struct PublicHTTPSResult {
    let host: String
    let passed: Bool
    let detail: String
}

private let publicHTTPSHosts = ["www.cloudflare.com", "www.baidu.com"]
typealias ProbeCommand = (String, [String], TimeInterval) throws -> CommandResult

// Prefer the phone's scoped DNS so a Wi-Fi/VPN resolver's synthetic answers do
// not become public HTTPS destinations. This does not change DNS or host routes.
func phoneDNSServers(_ text: String, interface: String) -> [String] {
    var scoped = false, matchesInterface = false
    var block: [String] = [], found: [String] = []
    func finish() {
        if scoped && matchesInterface { found += block }
        block = []; matchesInterface = false
    }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("DNS configuration") {
            finish()
            scoped = line.contains("for scoped queries")
        } else if line.hasPrefix("resolver #") {
            finish()
        } else if line.hasPrefix("if_index"), line.hasSuffix("(" + interface + ")") {
            matchesInterface = true
        } else if line.hasPrefix("nameserver["), let colon = line.firstIndex(of: ":") {
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let bare = String(value.split(separator: "%")[0])
            if let address = ipv6(bare, routable: false) {
                block.append(address.hasPrefix("fe80:") ? address + "%" + interface : address)
            } else {
                var address = in_addr()
                if inet_pton(AF_INET, value, &address) == 1 { block.append(value) }
            }
        }
    }
    finish()
    var unique: [String] = []
    for server in found where !unique.contains(server) { unique.append(server) }
    return Array((unique.filter { $0.contains(":") } + unique.filter { !$0.contains(":") }).prefix(2))
}

func publicProbeAddress(_ text: String) -> String? {
    guard let value = ipv6(text) else { return nil }
    var raw = in6_addr()
    guard inet_pton(AF_INET6, value, &raw) == 1 else { return nil }
    let b = withUnsafeBytes(of: raw) { Array($0) }
    // Global unicast only; exclude documentation and VPN benchmark/fake-IP space.
    guard b[0] & 0xe0 == 0x20,
          !(b[0...3] == [0x20, 0x01, 0x0d, 0xb8][...]),
          !(b[0...5] == [0x20, 0x01, 0x00, 0x02, 0x00, 0x00][...]) else { return nil }
    return value
}

private func probePublicHost(_ host: String, interface: String, servers: [String], run: ProbeCommand) -> PublicHTTPSResult {
    do {
        var addresses: [String] = []
        for server in servers {
            let answer = try run("/usr/bin/dig", ["@" + server, host, "AAAA", "+short", "+time=2", "+tries=1"], 3)
            if answer.code != 0 { continue }
            for line in answer.text.split(separator: "\n") {
                if let address = publicProbeAddress(String(line)), !addresses.contains(address) { addresses.append(address) }
            }
            if !addresses.isEmpty { break }
        }
        guard !addresses.isEmpty else { throw TetherError("手机 DNS 未返回公共 IPv6 地址（已排除 VPN 虚拟地址）。") }
        var failures: [String] = []
        for address in addresses.prefix(2) {
            // Pin the probed address and interface, while retaining hostname SNI
            // and certificate verification. Wi-Fi/proxy success cannot mask USB failure.
            let result = try run("/usr/bin/curl", ["-6", "--interface", interface, "--noproxy", "*",
                "--resolve", host + ":443:[" + address + "]", "--connect-timeout", "4", "--max-time", "6",
                "--silent", "--show-error", "--output", "/dev/null", "--write-out",
                "HTTP %{http_code}; peer %{remote_ip}; local %{local_ip}; TLS verify %{ssl_verify_result}",
                "https://" + host + "/"], 8)
            let detail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.code == 0 { return PublicHTTPSResult(host: host, passed: true, detail: detail) }
            failures.append(address + "：curl 退出码 \(result.code)；" + detail)
        }
        return PublicHTTPSResult(host: host, passed: false, detail: failures.joined(separator: "\n  "))
    } catch {
        return PublicHTTPSResult(host: host, passed: false, detail: error.localizedDescription)
    }
}

private final class ProbeResults {
    private let lock = NSLock()
    private var results: [Int: PublicHTTPSResult] = [:]
    func put(_ result: PublicHTTPSResult, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        results[index] = result
    }
    var ordered: [PublicHTTPSResult] {
        lock.lock(); defer { lock.unlock() }
        return results.keys.sorted().compactMap { results[$0] }
    }
}

func publicHTTPSProbes(interface: String, run: @escaping ProbeCommand = { try command($0, $1, timeout: $2) }) -> [PublicHTTPSResult] {
    do {
        guard matches(interface, "^feth[0-9]{1,10}$") else { throw TetherError("无效的手机 USB 接口。") }
        let dns = try run("/usr/sbin/scutil", ["--dns"], 4)
        guard dns.code == 0 else { throw TetherError("无法读取手机接口的 DNS 配置。") }
        let servers = phoneDNSServers(dns.text, interface: interface)
        guard !servers.isEmpty else { throw TetherError("手机接口未提供可用的专用 DNS，无法进行公网探测。") }
        let results = ProbeResults()
        DispatchQueue.concurrentPerform(iterations: publicHTTPSHosts.count) { index in
            results.put(probePublicHost(publicHTTPSHosts[index], interface: interface, servers: servers, run: run), at: index)
        }
        return results.ordered
    } catch {
        return publicHTTPSHosts.map { PublicHTTPSResult(host: $0, passed: false, detail: error.localizedDescription) }
    }
}
