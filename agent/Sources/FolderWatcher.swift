import CoreServices
import Foundation

/// Thin FSEvents wrapper around a single directory.
///
/// The stream is deliberately disposable: when the target lives on a removable
/// volume it disappears on eject, and the supervisor tears the watcher down and
/// builds a fresh one on remount rather than trying to keep a stale stream alive.
final class FolderWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    var isRunning: Bool { stream != nil }

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    func start() -> Bool {
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }

        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
