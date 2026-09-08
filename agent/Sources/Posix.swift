import Darwin

/// Thin libc wrappers.
///
/// The agent deliberately does not link Foundation. It is a daemon that formats
/// a timestamp, reads two small files, stats a directory and spawns a child;
/// Foundation, CoreFoundation and the Objective-C runtime cost several MB of
/// resident memory to provide none of that any better than libc does.
enum Posix {

    /// The invoking user's home directory. launchd sets HOME for a per-user
    /// agent, but fall back to the passwd database rather than trusting it.
    static func homeDirectory() -> String {
        if let home = getenv("HOME"), home.pointee != 0 {
            return String(cString: home)
        }
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return "/"
        }
        return String(cString: dir)
    }

    /// Reads a small text file whole. Returns nil for anything unreadable, and
    /// caps the read so a wrong path cannot pull an arbitrary file into memory.
    static func readSmallFile(_ path: String, limit: Int = 4096) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, limit) }
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// Appends one line to a file, creating it if needed.
    ///
    /// No lock is taken: a single write() to a file opened O_APPEND is atomic
    /// with respect to the file offset, so lines from different threads cannot
    /// interleave. That removes the need for a dedicated logging queue.
    static func appendLine(_ line: String, to path: String) {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes = Array(line.utf8)
        bytes.append(UInt8(ascii: "\n"))
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    static func fileSize(_ path: String) -> off_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_size
    }

    /// Seconds-resolution mtime, or nil when the path cannot be stat'd (which
    /// includes an unmounted volume).
    static func modificationTime(_ path: String) -> time_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mtimespec.tv_sec
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isExecutableFile(_ path: String) -> Bool {
        access(path, X_OK) == 0 && !isDirectory(path)
    }

    /// Local time as an ISO-8601-ish stamp with offset, e.g. 2026-09-09T02:15:03+0800.
    static func timestamp() -> String {
        var now = time(nil)
        var parts = tm()
        localtime_r(&now, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        let written = strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", &parts)
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }
}
