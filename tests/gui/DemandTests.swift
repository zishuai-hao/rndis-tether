import Foundation
import JavaScriptCore

@main
enum DemandTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TetherError(message) }
    }

    static func scriptResult(_ script: String, input: String) throws -> String {
        let context = JSContext()!
        context.evaluateScript(script)
        if let error = context.exception { throw TetherError(error.toString()) }
        let result = context.evaluateScript("JSON.stringify(main(" + input + ", 'test'))")
        if let error = context.exception { throw TetherError(error.toString()) }
        return result!.toString()
    }

    static func rejects(_ label: String = "expected rejection", _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw TetherError(label)
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 5, args[0] == "--control", let owner = Int32(args[4]) {
                let client = try ClashControl(endpoint: args[1], journal: URL(fileURLWithPath: args[2]))
                switch args[3] {
                case "enable": try client.enableUSB(owner: owner)
                case "restore": try client.restore(owner: owner)
                case "selection": print(try client.selection())
                default: throw TetherError("unknown test operation")
                }
                return
            }
            if args.count >= 2, args[0] == "--export-config" {
                let targets = args.count > 2 ? Array(args.dropFirst(2)) : ["example.com:443", "192.0.2.129/24:8000-8100", "[2001:db8::abcd/64]:443", "1.1.1.1", "2606:4700:4700::1111"]
                let preferences = DemandPreferences(targets: targets, dnsServer: "1.1.1.1")
                let result = try scriptResult(preferences.clashScript(), input: "{ipv6:false,mode:'rule',dns:{nameserver:['system']},rules:['MATCH,DIRECT']}")
                try Data(result.utf8).write(to: URL(fileURLWithPath: args[1]))
                return
            }
            let preferences = DemandPreferences(targets: [" Example.COM ", "example.com", "2001:db8:0::1"], dnsServer: " 1.1.1.1 ")
            let validated = try preferences.validated()
            try expect(validated.targets == ["example.com", "2001:db8::1"], "target normalization")
            try expect(validated.dnsServer == "1.1.1.1", "DNS normalization")
            for target in ["https://example.com", "example.com:0", "bad/name", "999.1.1.1", "fe80::1%feth50", "192.0.2.1\0junk", "a\nb"] {
                try rejects("accepted invalid target " + target) { _ = try DemandPreferences(targets: [target]).validated() }
            }
            try rejects { _ = try DemandPreferences(dnsServer: "dns.example.com").validated() }
            try rejects { _ = try DemandPreferences(targets: (1...9).map { "a\($0).example.com" }).validated() }
            let script = try preferences.clashScript()
            let result = try scriptResult(script, input: "{rules:['MATCH,DIRECT'],dns:{'enhanced-mode':'fake-ip','fake-ip-filter':['localhost']}}")
            let config = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
            let proxy = (config["proxies"] as! [[String: Any]])[0]
            try expect(proxy["type"] as? String == "direct" && proxy["interface-name"] as? String == "feth50" && proxy["ip-version"] as? String == "dual", "USB outbound")
            let group = (config["proxy-groups"] as! [[String: Any]])[0]
            try expect(group["proxies"] as? [String] == ["DIRECT", ClashControl.usb], "safe initial selector")
            try expect(config["rules"] as? [String] == ["DOMAIN-SUFFIX,example.com,RNDIS Tether", "IP-CIDR6,2001:db8::1/128,RNDIS Tether", "MATCH,DIRECT"], "rule ordering")
            try expect(config["ipv6"] as? Bool == true, "Clash IPv6 enabled")
            let dns = config["dns"] as! [String: Any]
            try expect(dns["fake-ip-filter"] as? [String] == ["localhost", "+.example.com"], "fake IP exclusion")
            let policy = dns["nameserver-policy"] as! [String: [String]]
            try expect(policy["+.example.com"] == ["1.1.1.1"], "domain DNS policy")
            try expect(script.components(separatedBy: "function main(").count == 2, "standalone main function")
            try expect(!script.contains("__rndisTetherOriginalMain"), "standalone export has no previous-script wrapper")
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rndis-script-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let installed = fixture.appendingPathComponent("Script.js")
            let backup = fixture.appendingPathComponent("previous.js")
            let oldScript = Data("throw new Error('previous script must be replaced');".utf8)
            try oldScript.write(to: installed)
            try preferences.installClashScript(at: installed, backup: backup)
            try expect(try Data(contentsOf: installed) == Data(script.utf8), "old script replaced completely")
            try expect(try Data(contentsOf: backup) == oldScript, "previous script backed up")
            try preferences.installClashScript(at: installed, backup: backup)
            try expect(try Data(contentsOf: backup) == oldScript, "repeat save preserves original backup")
            let missing = fixture.appendingPathComponent("absent/Script.js")
            try rejects { try preferences.installClashScript(at: missing, backup: backup) }
            try expect(!FileManager.default.fileExists(atPath: missing.path), "missing Clash installation is reported")
            try rejects { _ = try scriptResult(script, input: "{dns:{'enhanced-mode':'fake-ip','fake-ip-filter-mode':'whitelist'}}") }
            try rejects { _ = try scriptResult(script, input: "{proxies:[{name:'RNDIS Tether USB'}]}") }
            let examples: [(String, String, String)] = [
                ("Example.COM:0443", "example.com:443", "AND,((DOMAIN-SUFFIX,example.com),(DST-PORT,443)),RNDIS Tether"),
                ("192.0.2.255/25:8000-8100", "192.0.2.128/25:8000-8100", "AND,((IP-CIDR,192.0.2.128/25),(DST-PORT,8000-8100)),RNDIS Tether"),
                ("[2001:db8:ffff::/33]:443", "[2001:db8:8000::/33]:443", "AND,((IP-CIDR6,2001:db8:8000::/33),(DST-PORT,443)),RNDIS Tether"),
                ("192.0.2.1", "192.0.2.1", "IP-CIDR,192.0.2.1/32,RNDIS Tether"),
                ("2001:db8::443", "2001:db8::443", "IP-CIDR6,2001:db8::443/128,RNDIS Tether"),
                ("192.0.2.1/0", "0.0.0.0/0", "IP-CIDR,0.0.0.0/0,RNDIS Tether"),
                ("2001:db8::1/0", "::/0", "IP-CIDR6,::/0,RNDIS Tether")
            ]
            for (input, normalized, rule) in examples {
                let target = try RoutingTarget(input)
                try expect(target.normalized == normalized, "target normalization for " + input)
                try expect(target.clashRule(group: "RNDIS Tether") == rule, "rule for " + input)
            }
            for input in ["192.0.2.1/33", "2001:db8::1/129", "example.com/24", "192.0.2.1/-1", "1.2.3.4/", "1.2.3.4/24/8", "example.com:65536", "example.com:443-80", "example.com:443,80", "example.com:+443", "[2001:db8::1]443", "[2001:db8::1", "[1.2.3.4]:443", "[2001:db8::1]:", "192.0.2.1:1-2-3"] {
                try rejects("accepted invalid target " + input) { _ = try RoutingTarget(input) }
            }
            let combined = DemandPreferences(targets: examples.map { $0.0 }, dnsServer: "1.1.1.1")
            let combinedJSON = try scriptResult(combined.clashScript(), input: "{}")
            let combinedConfig = try JSONSerialization.jsonObject(with: Data(combinedJSON.utf8)) as! [String: Any]
            try expect(combinedConfig["rules"] as? [String] == examples.map { $0.2 }, "compiled mixed rules preserved")
            let combinedDNS = combinedConfig["dns"] as! [String: Any]
            try expect(combinedDNS["fake-ip-filter"] as? [String] == ["+.example.com"], "only domain targets receive DNS policies")
            print("PASS IPv4/IPv6, CIDR normalization, combined port conditions, preference validation and repeat export")

            let normal = Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{\"x\":1}".utf8)
            try expect(try ClashControl.decodeResponse(normal)["x"] as? Int == 1, "normal HTTP")
            let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{\"x\r\n4\r\n\":1}\r\n0\r\n\r\n".utf8)
            try expect(try ClashControl.decodeResponse(chunked)["x"] as? Int == 1, "chunked HTTP")
            try expect(try ClashControl.decodeResponse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)).isEmpty, "204 HTTP")
            for response in ["HTTP/1.1 404 Missing\r\n\r\n{}", "invalid", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nx", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naXX"] {
                try rejects { _ = try ClashControl.decodeResponse(Data(response.utf8)) }
            }
            try rejects { _ = try ClashControl(endpoint: "/tmp/socket", secret: "bad\r\nheader") }
            print("PASS local controller HTTP parsing, malformed response and header validation")
        } catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
