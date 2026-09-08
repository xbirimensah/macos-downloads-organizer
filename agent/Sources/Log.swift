import Darwin

/// Append-only logger with size-based rotation.
///
/// Writes are lock-free: a single write() to a file opened O_APPEND cannot
/// interleave with another, so no serial queue or mutex is needed even though
/// lines come from both the timer thread and the worker thread.
struct Log {
    let path: String

    func write(_ message: String) {
        rotateIfNeeded()
        let line = "\(Posix.timestamp()) [agent] \(message)"
        Posix.appendLine(line, to: path)

        // launchd captures stderr to the agent's .err file, which gives a
        // second copy for anyone tailing that instead.
        var bytes = Array(line.utf8)
        bytes.append(UInt8(ascii: "\n"))
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }

    private func rotateIfNeeded() {
        guard let size = Posix.fileSize(path), size > Config.maxLogBytes else { return }
        let previous = path + ".1"
        unlink(previous)
        rename(path, previous)
    }
}
