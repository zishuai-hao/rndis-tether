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

    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw TetherError("expected rejection")
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
            if args.count == 2, args[0] == "--export-config" {
                let preferences = DemandPreferences(targets: ["example.com"], dnsServer: "1.1.1.1")
                let result = try scriptResult(preferences.clashScript(), input: "{ipv6:false,mode:'rule',dns:{nameserver:['system']},rules:['MATCH,DIRECT']}")
                try Data(result.utf8).write(to: URL(fileURLWithPath: args[1]))
                return
            }
            let preferences = DemandPreferences(targets: [" Example.COM ", "example.com", "2001:db8:0::1"], dnsServer: " 1.1.1.1 ")
            let validated = try preferences.validated()
            try expect(validated.targets == ["example.com", "2001:db8::1"], "target normalization")
            try expect(validated.dnsServer == "1.1.1.1", "DNS normalization")
            for target in ["https://example.com", "example.com:443", "bad/name", "::1", "fe80::1", "a\nb"] {
                try rejects { _ = try DemandPreferences(targets: [target]).validated() }
            }
            try rejects { _ = try DemandPreferences(dnsServer: "dns.example.com").validated() }
            try rejects { _ = try DemandPreferences(targets: (1...9).map { "a\($0).example.com" }).validated() }
            let script = try preferences.clashScript(existingScript: "function main(config, name) { config.custom = name; return config; }")
            let result = try scriptResult(script, input: "{rules:['MATCH,DIRECT'],dns:{'enhanced-mode':'fake-ip','fake-ip-filter':['localhost']}}")
            let config = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
            try expect(config["custom"] as? String == "test", "existing script preserved")
            let proxy = (config["proxies"] as! [[String: Any]])[0]
            try expect(proxy["type"] as? String == "direct" && proxy["interface-name"] as? String == "feth50" && proxy["ip-version"] as? String == "ipv6", "USB outbound")
            let group = (config["proxy-groups"] as! [[String: Any]])[0]
            try expect(group["proxies"] as? [String] == ["DIRECT", ClashControl.usb], "safe initial selector")
            try expect(config["rules"] as? [String] == ["DOMAIN-SUFFIX,example.com,RNDIS Tether", "IP-CIDR6,2001:db8::1/128,RNDIS Tether,no-resolve", "MATCH,DIRECT"], "rule ordering")
            try expect(config["ipv6"] as? Bool == true, "Clash IPv6 enabled")
            let dns = config["dns"] as! [String: Any]
            try expect(dns["fake-ip-filter"] as? [String] == ["localhost", "+.example.com"], "fake IP exclusion")
            let policy = dns["nameserver-policy"] as! [String: [String]]
            try expect(policy["+.example.com"] == ["1.1.1.1"], "domain DNS policy")
            let regenerated = try preferences.clashScript(existingScript: script)
            try expect(try scriptResult(regenerated, input: "{}") == scriptResult(script, input: "{}"), "idempotent export")
            try rejects { _ = try preferences.clashScript(existingScript: "// BEGIN RNDIS TETHER MANAGED CONFIG") }
            try rejects { _ = try scriptResult(script, input: "{dns:{'enhanced-mode':'fake-ip','fake-ip-filter-mode':'whitelist'}}") }
            try rejects { _ = try scriptResult(script, input: "{proxies:[{name:'RNDIS Tether USB'}]}") }
            print("PASS preference validation, JavaScript execution, existing script preservation and repeat export")

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
