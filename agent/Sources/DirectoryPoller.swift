import Darwin
import Dispatch

/// Watches a directory by polling its modification time.
///
/// This is the only change signal the agent uses, because FSEvents cannot be
/// relied on for every filesystem: the target may sit on an exFAT volume
/// mounted through fskit, whose `.fseventsd` carries a UUID and no event log,
/// so a stream there stays silent no matter how many files appear. A
/// directory's mtime does change on every entry added or removed, on every
/// filesystem tested, which makes a single `stat` per tick dependable.
///
/// FSEvents was removed rather than kept as a fast path: it linked
/// CoreServices, CoreFoundation and Foundation for, at best, a two second head
/// start that is invisible behind the six second debounce that follows it.
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
        lastModified = Posix.modificationTime(path)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Config.pollIntervalSeconds,
            repeating: Config.pollIntervalSeconds,
            leeway: .milliseconds(Int(Config.pollLeewaySeconds * 1000))
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
        guard let current = Posix.modificationTime(path) else { return }
        defer { lastModified = current }
        guard let previous = lastModified, previous != current else { return }
        onChange()
    }
}
