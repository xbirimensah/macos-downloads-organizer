import Foundation

/// Resolved runtime configuration. Mirrors the worker's own target resolution
/// (ORGANIZE_DL env > target file > ~/Downloads) so the agent and the script
/// never disagree about which folder is being organised.
struct Config {
    let targetPath: String
    let workerPath: String
    let logPath: String

    /// Quiet period after the last filesystem event before the worker runs.
    ///
    /// Coalesces the burst of events a single download or copy produces, and is
    /// deliberately longer than the worker's own 5s settle guard (which skips
    /// files that may still be downloading). If this dropped below that guard,
    /// the triggered run would skip the very file that woke it and the file
    /// would wait for the next periodic sweep instead.
    static let debounceSeconds = 6.0

    /// How often the mtime poller checks the target. Cheap (one stat) and the
    /// only dependable change signal on filesystems where FSEvents is silent.
    static let pollIntervalSeconds = 3.0

    /// Safety-net full sweep, in case both change signals are ever missed.
    static let sweepIntervalSeconds = 600.0

    /// How often to re-check whether the target exists. Drives re-arming the
    /// watcher when an external volume is ejected and plugged back in.
    static let supervisorIntervalSeconds = 30.0

    /// Cap before the agent log is rotated, matching the worker's own limit.
    static let maxLogBytes = 5 * 1024 * 1024

    static func resolve() -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Config(
            targetPath: resolveTarget(home: home),
            workerPath: "\(home)/bin/organize-downloads.sh",
            logPath: "\(home)/Library/Logs/organize-downloads-agent.log"
        )
    }

    private static func resolveTarget(home: String) -> String {
        if let fromEnv = ProcessInfo.processInfo.environment["ORGANIZE_DL"],
           !fromEnv.isEmpty {
            return fromEnv
        }
        let targetFile = "\(home)/.config/organize-downloads/target"
        if let raw = try? String(contentsOfFile: targetFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "\(home)/Downloads"
    }
}
