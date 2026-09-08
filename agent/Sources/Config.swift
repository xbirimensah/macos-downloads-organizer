import Darwin

/// Resolved runtime configuration. Mirrors the worker's own target resolution
/// (ORGANIZE_DL env > target file > ~/Downloads) so the agent and the script
/// never disagree about which folder is being organised.
struct Config {
    let targetPath: String
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

    /// How often the target's mtime is checked. One stat per tick.
    static let pollIntervalSeconds = 3.0

    /// Slack given to the kernel to coalesce poll wakeups with other timers.
    /// Without it a 3s repeating timer wakes the CPU ~28k times a day on its
    /// own schedule; with it those wakeups ride along with existing ones.
    static let pollLeewaySeconds = 2.0

    /// Safety-net full sweep, in case a change is ever missed entirely.
    static let sweepIntervalSeconds = 600.0

    /// How often to re-check whether the target exists. Drives re-arming the
    /// poller when a removable volume is ejected and plugged back in.
    static let supervisorIntervalSeconds = 30.0

    /// Cap before the agent log is rotated, matching the worker's own limit.
    static let maxLogBytes: off_t = 5 * 1024 * 1024

    static func resolve() -> Config {
        let home = Posix.homeDirectory()
        return Config(
            targetPath: resolveTarget(home: home),
            workerPath: "\(home)/bin/organize-downloads.sh",
            logPath: "\(home)/Library/Logs/organize-downloads-agent.log"
        )
    }

    private static func resolveTarget(home: String) -> String {
        if let raw = getenv("ORGANIZE_DL") {
            let value = String(cString: raw)
            if !value.isEmpty { return value }
        }
        if let raw = Posix.readSmallFile("\(home)/.config/organize-downloads/target") {
            let value = raw.trimmingASCIIWhitespace()
            if !value.isEmpty { return value }
        }
        return "\(home)/Downloads"
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
