import Foundation

@main
enum ResourcePathProbe {
    static func main() {
        // Populate Foundation's bundle cache before the parent moves this app.
        _ = Bundle.main.resourceURL!.path
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        _ = FileHandle.standardInput.readData(ofLength: 1)
        do {
            let resources = appResourcesDirectory()
            guard resources == CommandLine.arguments[1] else {
                throw TetherError("Stale resources path: " + resources)
            }
            let result = try command(resources + "/rndis-tether-gui-helper", [])
            guard result.code == 0, result.text == "probe-ok\n" else {
                throw TetherError("Moved helper could not run")
            }
            print("PASS: running app finds and executes its helper after being moved")
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
}
