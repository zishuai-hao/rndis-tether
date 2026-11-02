import Foundation

@main
enum TrustedPathsTests {
    static func main() {
        var failures = 0
        for path in ["/var/db", "/var", "/private/var/db", "/etc", "/private/etc", "/", "/Library"] {
            do {
                try trustedDirectory(path)
                print("PASS trusted system directory: " + path)
            } catch {
                failures += 1
                print("FAIL trusted system directory \(path): \(error.localizedDescription)")
            }
        }
        for path in ["/tmp", "/private/tmp", "/var/tmp", "/usr/bin/true", "/var/db/rndis-tether-gui-no-such-regression-directory"] {
            do {
                try trustedDirectory(path)
                failures += 1
                print("FAIL accepted unsafe/non-directory/missing path: " + path)
            } catch { print("PASS rejected unsafe/non-directory/missing path: " + path) }
        }
        do { try checkSystemDirectories(); print("PASS installation system-directory preflight") }
        catch { failures += 1; print("FAIL installation preflight: " + error.localizedDescription) }
        print("Directory validation failures: \(failures). Read-only checks; no root required.")
        exit(failures == 0 ? 0 : 1)
    }
}
