import Foundation

/// Watches a directory by polling its modification time.
///
/// This exists because FSEvents cannot be relied on for every filesystem. The
/// organiser's target may sit on an exFAT volume mounted through fskit, whose
/// `.fseventsd` carries a UUID and no event log, so an FSEvents stream there
/// stays silent no matter how many files appear. A directory's mtime does still
/// change on every entry added or removed, on every filesystem tested, which
/// makes a single `stat` per tick a dependable floor.
///
/// Cost is one stat call per interval, so this runs alongside FSEvents rather
/// than instead of it: whichever notices first wins, and the shared debounce
/// collapses a doubled signal into one worker run.
final class DirectoryPoller {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var timer: DispatchSourceTimer?
    private var lastModified: time_t?

    var isRunning: Bool { timer != nil }

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }

        // Seed the baseline so starting the poller does not itself count as a
        // change; the caller already runs a reconcile sweep on start.
        lastModified = modificationTime()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Config.pollIntervalSeconds,
            repeating: Config.pollIntervalSeconds
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastModified = nil
    }

    private func tick() {
        guard let current = modificationTime() else { return }
        defer { lastModified = current }
        guard let previous = lastModified, previous != current else { return }
        onChange()
    }

    private func modificationTime() -> time_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mtimespec.tv_sec
    }
}
