import Darwin
import Dispatch

/// Runs the bash worker as a child of this app.
///
/// Keeping the worker as a child is deliberate: TCC attributes the child's file
/// access to its responsible process, which is this bundle. The app holds the
/// grants, so the script inherits them without needing any of its own. Runs are
/// serialised so a slow sweep can never overlap the next trigger.
final class WorkerRunner {
    /// Most stderr retained from a run. Only the tail is ever logged, but the
    /// pipe must still be drained fully or a chatty child would block on write.
    private static let maxCapturedStderr = 2048

    private let config: Config
    private let log: Log
    private let queue = DispatchQueue(label: "local.organize-downloads.worker")
    private var isRunning = false

    /// Called with the worker's exit status after every completed run, on the
    /// worker queue. Runs that never launched do not report.
    var onExit: ((Int32) -> Void)?

    init(config: Config, log: Log) {
        self.config = config
        self.log = log
    }

    func run(reason: String) {
        queue.async { [self] in
            guard !isRunning else {
                log.write("skipped (\(reason)): a run is already in progress")
                return
            }
            isRunning = true
            defer { isRunning = false }
            execute(reason: reason)
        }
    }

    private func execute(reason: String) {
        guard Posix.isExecutableFile(config.workerPath) else {
            log.write("worker missing or not executable: \(config.workerPath)")
            return
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            log.write("worker failed: cannot create pipe")
            return
        }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var pid: pid_t = 0
        let status = withCStringArray(["/bin/bash", config.workerPath]) { argv in
            withCStringArray(childEnvironment()) { envp in
                posix_spawn(&pid, "/bin/bash", &actions, nil, argv, envp)
            }
        }

        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            log.write("worker failed to launch: errno \(status)")
            return
        }

        let stderrTail = drain(readEnd)
        close(readEnd)

        var exitStatus: Int32 = 0
        while waitpid(pid, &exitStatus, 0) == -1 && errno == EINTR { continue }

        let code = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1
        if code != 0 && code != Config.workerDeferredExitCode {
            log.write("worker exited \(code) (\(reason))")
        }
        let trimmed = stderrTail.trimmingASCIIWhitespace()
        if !trimmed.isEmpty {
            log.write("worker stderr: \(trimmed)")
        }
        onExit?(code)
    }

    /// Reads the pipe to EOF, retaining only the final `maxCapturedStderr`
    /// bytes so a runaway child cannot grow this process's memory.
    private func drain(_ fd: Int32) -> String {
        var kept: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 1024) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            kept.append(contentsOf: chunk[0..<count])
            if kept.count > Self.maxCapturedStderr {
                kept.removeFirst(kept.count - Self.maxCapturedStderr)
            }
        }
        return String(decoding: kept, as: UTF8.self)
    }

    /// The current environment with ORGANIZE_DL and ORGANIZE_INBOX forced to
    /// the resolved values, so the worker cannot disagree with the agent about
    /// what to organise. The inbox is always stated: the worker treats an env
    /// target with no env inbox as "do not relay", so silence would disable it.
    private func childEnvironment() -> [String] {
        var result: [String] = []
        var index = 0
        while let entry = environ[index] {
            let text = String(cString: entry)
            if !text.hasPrefix("ORGANIZE_DL=") && !text.hasPrefix("ORGANIZE_INBOX=") {
                result.append(text)
            }
            index += 1
        }
        result.append("ORGANIZE_DL=\(config.targetPath)")
        result.append("ORGANIZE_INBOX=\(config.inboxPath ?? "off")")
        return result
    }
}

/// Builds a NULL-terminated C string array for posix_spawn and frees it after.
private func withCStringArray<R>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
