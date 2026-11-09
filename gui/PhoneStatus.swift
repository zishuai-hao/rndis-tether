import Foundation

func phoneIPv6Gateway(_ interface: String) throws -> String? {
    guard matches(interface, "^feth[0-9]{1,10}$") else { return nil }
    let config = try command("/sbin/ifconfig", [interface])
    guard config.code == 0, config.text.split(separator: "\n").contains(where: { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        return fields.count >= 2 && fields[0] == "inet6" && ipv6(String(fields[1])) != nil
    }) else { return nil }
    let table = try checked("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
    for line in table.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if fields.count >= 4, fields[0] == "default", fields[3] == interface,
           let gateway = ipv6(String(fields[1].split(separator: "%")[0]), routable: false), gateway.hasPrefix("fe80:") {
            return gateway + "%" + interface
        }
    }
    return nil
}
