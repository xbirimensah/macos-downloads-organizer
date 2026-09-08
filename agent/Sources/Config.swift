import Darwin

/// Resolved runtime configuration. Mirrors the worker's own resolution rules
/// (ORGANIZE_DL env > target file > ~/Downloads, and ORGANIZE_INBOX env >
/// inbox file > none) so the agent and the script never disagree about which
/// folders are being organised.
struct Config {
    let targetPath: String
    /// Optional second folder the worker drains into the target before every
    /// sweep. nil when none is configured or it would equal the target.
    let inboxPath: String?
    let workerPath: String
    let logPath: String

    /// Quiet period after the last observed change before the worker runs.
    ///
    /// Coalesces the burst a single download or copy produces, and is
    /// deliberately longer than the worker's own 5s settle guard (which skips
    /// files that may still be downloading). If this dropped below that guard,
    /// the triggered run would skip the very file that woke it and the file
    /// would wait for the next periodic sweep instead.
    static let debounceSeconds = 6.0

    /// How often each watched folder's mtime is checked. One stat per tick.
    static let pollIntervalSeconds = 3.0

    /// Slack given to the kernel to coalesce poll wakeups with other timers.
    /// Without it a 3s repeating timer wakes the CPU ~28k times a day on its
    /// own schedule; with it those wakeups ride along with existing ones.
    static let pollLeewaySeconds = 2.0

    /// Safety-net full sweep, in case a change is ever missed entirely.
    static let sweepIntervalSeconds = 600.0

    /// How often to re-check whether the target exists. Drives re-arming the
    /// pollers when a removable volume is ejected and plugged back in.
    static let supervisorIntervalSeconds = 30.0

    /// Cap before the agent log is rotated, matching the worker's own limit.
    static let maxLogBytes: off_t = 5 * 1024 * 1024

    /// Exit status the worker uses to say it left entries behind that were
    /// still being written. Not an error: the agent retries on a backoff.
    static let workerDeferredExitCode: Int32 = 3

    /// First retry delay after a deferred run, doubled per consecutive
    /// deferral up to `retryMaxSeconds`. Bounds how long a file written in
    /// place (no temp name, so no second mtime change on the folder) waits
    /// after the writer finishes.
    static let retryInitialSeconds = 15.0
    static let retryMaxSeconds = 60.0

    static func resolve() -> Config {
        let home = Posix.homeDirectory()
        let target = resolveTarget(home: home)
        return Config(
            targetPath: target,
            inboxPath: resolveInbox(home: home, target: target),
            workerPath: "\(home)/bin/organize-downloads.sh",
            logPath: "\(home)/Library/Logs/organize-downloads-agent.log"
        )
    }

    private static func resolveTarget(home: String) -> String {
        if let value = environmentValue("ORGANIZE_DL") { return value }
        if let raw = Posix.readSmallFile("\(home)/.config/organize-downloads/target") {
            let value = raw.trimmingASCIIWhitespace()
            if !value.isEmpty { return value }
        }
        return "\(home)/Downloads"
    }

    /// An env-overridden target never relays unless ORGANIZE_INBOX is also
    /// given, matching the worker: a one-off run pointed somewhere else must
    /// not drain ~/Downloads into it.
    private static func resolveInbox(home: String, target: String) -> String? {
        let raw: String?
        if let env = getenv("ORGANIZE_INBOX") {
            raw = String(cString: env)
        } else if environmentValue("ORGANIZE_DL") != nil {
            return nil
        } else {
            raw = Posix.readSmallFile("\(home)/.config/organize-downloads/inbox")
        }
        guard var path = raw?.trimmingASCIIWhitespace(), !path.isEmpty,
              path != "off", path != "none"
        else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path == target ? nil : path
    }

    /// The variable's value, or nil when unset or empty.
    private static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

extension String {
    /// Foundation-free equivalent of trimming whitespace and newlines, enough
    /// for a single-line config value written by a shell redirect.
    func trimmingASCIIWhitespace() -> String {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let first = firstIndex(where: { !isBlank($0) }),
              let last = lastIndex(where: { !isBlank($0) })
        else { return "" }
        return String(self[first...last])
    }
}
