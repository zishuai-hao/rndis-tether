import Foundation
import Darwin

// Shared with the read-only filesystem regression tests.
func trustedDirectory(_ path: String, create: Bool = false, mode: mode_t = 0o755) throws {
    if create && !FileManager.default.fileExists(atPath: path) {
        // Validate the existing parent before creating anything as root.
        try trustedDirectory((path as NSString).deletingLastPathComponent)
        guard mkdir(path, mode) == 0 else { throw TetherError("无法创建 \(path)：\(String(cString: strerror(errno)))") }
    }
    // Foundation resolves /private/var back to the display alias /var, even after
    // resolvingSymlinksInPath(). lstat then sees the system symlink, not a directory.
    // Use the same POSIX canonicalization as the C daemon's trusted hook check.
    guard let resolved = realpath(path, nil) else {
        throw TetherError("无法解析系统目录 \(path)：\(String(cString: strerror(errno)))")
    }
    var current = String(cString: resolved)
    free(resolved)
    while true {
        var info = stat()
        guard lstat(current, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw TetherError("系统目录权限不安全：\(current)") }
        if current == "/" { return }
        // Keep the canonical string: Foundation URL operations can restore aliases.
        let slash = current.lastIndex(of: "/")!
        current = slash == current.startIndex ? "/" : String(current[..<slash])
    }
}

func checkSystemDirectories() throws {
    for path in ["/var/db", "/etc", "/Library"] { try trustedDirectory(path) }
    for path in [Paths.stateDir, "/Library/PrivilegedHelperTools", "/etc/resolver"] {
        if FileManager.default.fileExists(atPath: path) { try trustedDirectory(path) }
    }
}
