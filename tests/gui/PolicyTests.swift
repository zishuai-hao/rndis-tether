import Foundation

final class FakeSystem: RouteSystem {
    var router: String? = "fe80::1%feth50"
    var answers = ["server.example.com": ["2001:db8::10"]]
    var routes: [String: Hop] = [:]
    var lookups = 0
    var additions = 0
    var deletions = 0
    var failDNS = false
    var failSet: String?
    var failDelete = false
    func gateway(_ interface: String) throws -> String? { router }
    func resolve(_ target: String) throws -> [String] {
        lookups += 1
        if failDNS { throw TetherError("temporary DNS failure") }
        return ipv6(target).map { [$0] } ?? answers[target] ?? []
    }
    func route(_ address: String) throws -> Hop? { routes[address] }
    func set(_ address: String, hop: Hop, replacing: Bool) throws {
        if failSet == address { throw TetherError("route mutation failed") }
        routes[address] = hop; additions += 1
    }
    func delete(_ address: String, hop: Hop) throws {
        if failDelete { throw TetherError("route deletion failed") }
        routes.removeValue(forKey: address); deletions += 1
    }
}

@main
enum PolicyTests {
    static var passed = 0
    static func test(_ name: String, _ block: () throws -> Void) throws {
        try block(); passed += 1; print("PASS " + name)
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String = "assertion failed") throws {
        if try !condition() { throw TetherError(reason) }
    }
    static func rejects(_ block: () throws -> Void) throws {
        do { try block() } catch { return }
        throw TetherError("expected rejection")
    }
    static func sync(_ state: inout RouteState, _ system: FakeSystem, targets: [String] = ["server.example.com"], now: Double = 1, force: Bool = false) throws {
        _ = try reconcile(&state, interface: "feth50", targets: targets, system: system, now: now, forceDNS: force)
    }
    static func main() {
        do {
            try test("normalize and deduplicate destinations") {
                let value = try GUIConfig(targets: [" SERVER.example.com ", "server.example.com", "2001:0db8::10"]).validated()
                try expect(value.targets == ["server.example.com", "2001:db8::10"])
                try expect(try JSONDecoder().decode(GUIConfig.self, from: value.encoded()) == value)
            }
            try test("reject URLs, shell text, scoped/link-local and non-unicast IPv6") {
                for value in ["https://server.example.com", "foo;touch /tmp/pwn", "-foo.com", "foo..com", "a/b", "fe80::1", "fe80::1%feth50", "::", "::1", "ff02::1", "::ffff:127.0.0.1"] {
                    try rejects { _ = try GUIConfig(targets: [value]).validated() }
                }
            }
            try test("validate optional DNS and eight-target limit") {
                _ = try GUIConfig(targets: ["example.com"], dnsServer: "1.1.1.1").validated()
                _ = try GUIConfig(targets: ["example.com"], dnsServer: "2606:4700:4700::1111").validated()
                try rejects { _ = try GUIConfig(targets: ["example.com"], dnsServer: "1.1.1.1\nsearch evil").validated() }
                try rejects { _ = try GUIConfig(targets: (1...9).map { "s\($0).example.com" }).validated() }
                try rejects { _ = try GUIConfig().validated() }
                _ = try GUIConfig(enabled: false).validated()
            }
            try test("select only the phone's scoped IPv6 default gateway") {
                let table = "default fe80::2%en0 UGcIg en0\ndefault fe80::1%feth50 UGcIg feth50\n"
                try expect(parseGateway(table, interface: "feth50") == "fe80::1%feth50")
                try expect(parseGateway(table, interface: "feth51") == nil)
            }
            try test("never treat a prefix/default route as an owned host route") {
                let text = "destination: 2001:db8::10\ngateway: fe80::1\ninterface: feth50\nflags: <UP,GATEWAY,HOST,DONE>\n"
                try expect(parseRoute(text, address: "2001:db8::10") == Hop(interface: "feth50", gateway: "fe80::1%feth50"))
                try expect(parseRoute(text.replacingOccurrences(of: ",HOST", with: ""), address: "2001:db8::10") == nil)
                try expect(parseRoute(text, address: "2001:db8::11") == nil)
            }
            try test("idempotent route installation and DNS cache") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); try sync(&state, system, now: 2)
                try expect(system.additions == 1 && system.lookups == 1 && state.owned.count == 1)
            }
            try test("periodic refresh replaces old AAAA routes") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system)
                system.answers["server.example.com"] = ["2001:db8::11"]
                try sync(&state, system, now: 299, force: true)
                try expect(system.lookups == 2 && system.deletions == 1)
                try expect(system.routes["2001:db8::11"] != nil && system.routes["2001:db8::10"] == nil)
            }
            try test("reconnect uses a new phone gateway before DNS expiry") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); system.router = "fe80::2%feth50"
                try sync(&state, system, now: 2)
                try expect(system.lookups == 2 && system.routes["2001:db8::10"]?.gateway == "fe80::2%feth50")
            }
            try test("missing interface cleans owned routes and reconnect restores them") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); system.router = nil; try sync(&state, system, now: 2)
                try expect(system.routes.isEmpty && state.owned.isEmpty)
                system.router = "fe80::3%feth50"; try sync(&state, system, now: 3)
                try expect(system.routes.count == 1)
            }
            try test("transient DNS error retains last good addresses") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); system.failDNS = true; try sync(&state, system, now: 302)
                try expect(system.routes.count == 1 && system.deletions == 0)
                try expect(state.cache["server.example.com"]?.expires == 362)
            }
            try test("disable removes only GUI-owned host routes") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); try sync(&state, system, targets: [])
                try expect(system.routes.isEmpty && state.cache.isEmpty && state.owned.isEmpty)
            }
            try test("VPN replacement survives stale route cleanup") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system)
                system.routes["2001:db8::10"] = Hop(interface: "utun4", gateway: "2001:db8::99")
                try sync(&state, system, targets: [])
                try expect(system.deletions == 0 && system.routes.count == 1 && state.owned.isEmpty)
            }
            try test("matching administrator route is never silently adopted") {
                var state = RouteState(); let system = FakeSystem()
                let existing = Hop(interface: "feth50", gateway: "fe80::1%feth50")
                system.routes["2001:db8::10"] = existing
                try sync(&state, system); try sync(&state, system, targets: [])
                try expect(state.owned.isEmpty && system.routes["2001:db8::10"] == existing)
            }
            try test("partial route mutation failure retains ownership for retry") {
                var state = RouteState(); let system = FakeSystem()
                system.answers["server.example.com"] = ["2001:db8::10", "2001:db8::11"]
                system.failSet = "2001:db8::11"
                try rejects { try sync(&state, system) }
                try expect(state.owned.count == 1 && state.owned["2001:db8::10"] != nil)
            }
            try test("failed deletion keeps ownership until the next reconciliation") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system); system.failDelete = true
                try rejects { try sync(&state, system, targets: []) }
                try expect(state.owned.count == 1)
                system.failDelete = false; try sync(&state, system, targets: [])
                try expect(state.owned.isEmpty)
            }
            try test("ownership checkpoints precede subsequent route mutations") {
                var state = RouteState(); let system = FakeSystem()
                system.answers["server.example.com"] = ["2001:db8::10", "2001:db8::11"]
                system.failSet = "2001:db8::11"
                var snapshots: [RouteState] = []
                try rejects {
                    _ = try reconcile(&state, interface: "feth50", targets: ["server.example.com"], system: system,
                                      now: 1, checkpoint: { snapshots.append($0) })
                }
                try expect(snapshots.count == 1 && snapshots[0].owned["2001:db8::10"] != nil)
            }
            try test("literal destination and independent shell/AppleScript quoting") {
                var state = RouteState(); let system = FakeSystem()
                try sync(&state, system, targets: ["2001:db8::42"])
                try expect(system.routes["2001:db8::42"] != nil)
                let value = "a'b $HOME `printf bad` \"\\ unicode 中文"
                let output = try checked("/bin/sh", ["-c", "printf '%s' " + shellQuote(value)])
                try expect(output == value)
                try expect(appleScriptLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"")
            }
            print("\(passed) GUI policy tests passed; no system configuration changed.")
        } catch {
            FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
