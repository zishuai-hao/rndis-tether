import Foundation

private let dnsFixture = """
DNS configuration
resolver #1
  nameserver[0] : 9.9.9.9
DNS configuration (for scoped queries)
resolver #1
  nameserver[0] : 192.0.2.1
  if_index : 6 (en0)
resolver #2
  nameserver[0] : 2001:db8::53
  if_index : 22 (feth50)
"""

private final class FakeProbe {
    let lock = NSLock()
    var dns = dnsFixture
    var answers = "2606:4700::100\n"
    var failures = Set<String>()
    var calls: [(String, [String])] = []
    func run(_ path: String, _ args: [String], _ timeout: TimeInterval) throws -> CommandResult {
        lock.lock(); calls.append((path, args)); lock.unlock()
        if path == "/usr/sbin/scutil" { return CommandResult(code: 0, text: dns) }
        if path == "/usr/bin/dig" { return CommandResult(code: 0, text: answers) }
        if path == "/usr/bin/curl" {
            let fails = failures.contains(args.last ?? "")
            return CommandResult(code: fails ? 28 : 0, text: fails ? "connection timeout" : "HTTP 403; TLS verify 0")
        }
        throw TetherError("unexpected command")
    }
}

@main
enum HTTPSProbeTests {
    static func expect(_ condition: @autoclosure () -> Bool) throws {
        if !condition() { throw TetherError("probe regression assertion failed") }
    }
    static func main() {
        do {
            try expect(phoneDNSServers(dnsFixture, interface: "feth50") == ["2001:db8::53"])
            try expect(phoneDNSServers(dnsFixture, interface: "feth51").isEmpty)
            let linkLocal = dnsFixture.replacingOccurrences(of: "2001:db8::53", with: "fe80::53")
            try expect(phoneDNSServers(linkLocal, interface: "feth50") == ["fe80::53%feth50"])
            print("PASS: use only the selected phone's scoped DNS, including link-local scopes")

            for address in ["2001:2::10", "2001:db8::1", "fd00::1", "fe80::1", "::1", "198.18.0.1", "not-an-address"] {
                try expect(publicProbeAddress(address) == nil)
            }
            try expect(publicProbeAddress("2606:4700::100") != nil)
            print("PASS: reject VPN fake-IP, documentation and non-public destinations")

            let fake = FakeProbe()
            let all = publicHTTPSProbes(interface: "feth50", run: fake.run)
            try expect(all.map { $0.host } == ["www.cloudflare.com", "www.baidu.com"])
            try expect(all.allSatisfy { $0.passed })
            let curls = fake.calls.filter { $0.0 == "/usr/bin/curl" }.map { $0.1 }
            try expect(curls.count == 2)
            for args in curls {
                try expect(args.contains("--interface") && args.contains("feth50"))
                try expect(args.contains("--noproxy") && args.contains("*"))
                try expect(args.contains("--resolve") && args.contains("-6"))
                try expect(!args.contains("--insecure") && !args.contains("-k"))
                try expect(args.last == "https://www.cloudflare.com/" || args.last == "https://www.baidu.com/")
            }
            try expect(fake.calls.allSatisfy { ["/usr/sbin/scutil", "/usr/bin/dig", "/usr/bin/curl"].contains($0.0) })
            print("PASS: both public HTTPS endpoints retain TLS verification, use USB and never mutate routes/DNS")

            let partial = FakeProbe(); partial.failures = ["https://www.cloudflare.com/"]
            let some = publicHTTPSProbes(interface: "feth50", run: partial.run)
            try expect(some.filter { $0.passed }.count == 1 && some.contains { $0.passed })
            print("PASS: one blocked public site does not hide the other's successful IPv6 HTTPS")

            let failed = FakeProbe(); failed.failures = ["https://www.cloudflare.com/", "https://www.baidu.com/"]
            try expect(!publicHTTPSProbes(interface: "feth50", run: failed.run).contains { $0.passed })
            print("PASS: both failed public sites cannot report a working HTTPS exit")

            let noDNS = FakeProbe(); noDNS.dns = "DNS configuration\nresolver #1\n  nameserver[0] : 192.0.2.1\n"
            try expect(publicHTTPSProbes(interface: "feth50", run: noDNS.run).allSatisfy { !$0.passed })
            try expect(noDNS.calls.count == 1)
            let fakeDNS = FakeProbe(); fakeDNS.answers = "2001:2::10\n"
            try expect(publicHTTPSProbes(interface: "feth50", run: fakeDNS.run).allSatisfy { !$0.passed })
            try expect(!fakeDNS.calls.contains { $0.0 == "/usr/bin/curl" })
            print("PASS: missing phone DNS and fake-only answers fail without Wi-Fi fallback")

            for address in ["0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "1.1.1.1\0junk"] {
                try expect(publicProbeAddress(address, family: .ipv4) == nil)
            }
            try expect(publicProbeAddress("1.1.1.1", family: .ipv4) == "1.1.1.1")
            let dualDNS = dnsFixture.replacingOccurrences(of: "nameserver[0] : 2001:db8::53", with: "nameserver[0] : 2001:db8::53\n  nameserver[1] : 192.0.2.53")
            try expect(phoneDNSServers(dualDNS, interface: "feth50", family: .ipv4).first == "192.0.2.53")
            let v4 = FakeProbe(); v4.answers = "1.1.1.1\n"
            let v4Results = publicHTTPSProbes(interface: "feth50", family: .ipv4, run: v4.run)
            try expect(v4Results.count == 2 && v4Results.allSatisfy { $0.passed })
            for (_, args) in v4.calls.filter({ $0.0 == "/usr/bin/curl" }) {
                try expect(args.contains("-4") && !args.contains("-6"))
                try expect(args.contains("--interface") && args.contains("feth50"))
                try expect(args.contains("--resolve") && args.contains { $0.hasSuffix(":443:1.1.1.1") })
            }
            try expect(v4.calls.filter { $0.0 == "/usr/bin/dig" }.allSatisfy { $0.1.contains("A") && !$0.1.contains("AAAA") })
            print("PASS: IPv4-only USB HTTPS uses A records and interface binding with public-address validation")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
