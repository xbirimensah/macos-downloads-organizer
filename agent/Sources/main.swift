import Foundation

// Persistent agent for the Downloads Organizer.
//
// Replaces the AppleScript applet that launchd used to relaunch every 60s. One
// long-lived process means the TCC grant is negotiated once at launch instead of
// 1440 times a day, which is what made permission prompts recur endlessly.

let config = Config.resolve()
let logger = Logger(path: config.logPath)
let runner = WorkerRunner(config: config, logger: logger)

let eventQueue = DispatchQueue(label: "local.organize-downloads.events")
var pendingRun: DispatchWorkItem?

/// Collapses a burst of filesystem events into a single worker run once the
/// folder has been quiet for `debounceSeconds`.
func scheduleDebouncedRun() {
    pendingRun?.cancel()
    let work = DispatchWorkItem { runner.run(reason: "fsevent") }
    pendingRun = work
    eventQueue.asyncAfter(deadline: .now() + Config.debounceSeconds, execute: work)
}

// Two independent change signals feeding one debounce. FSEvents is instant
// where the filesystem supports it; the poller is the floor for the ones where
// it does not (see DirectoryPoller for the exFAT/fskit case).
let watcher = FolderWatcher(path: config.targetPath, queue: eventQueue) {
    scheduleDebouncedRun()
}

let poller = DirectoryPoller(path: config.targetPath, queue: eventQueue) {
    scheduleDebouncedRun()
}

func targetExists() -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: config.targetPath, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}

/// Keeps the watcher in step with the target's availability. The target can live
/// on a removable volume, so it legitimately comes and goes.
///
/// `reportedUnavailable` keeps the "can't see the target" message to once per
/// outage instead of once every supervisor tick.
var reportedUnavailable = false

func superviseWatcher() {
    let available = targetExists()

    if available {
        reportedUnavailable = false
    } else if !reportedUnavailable {
        reportedUnavailable = true
        logger.log("target not reachable: \(config.targetPath) "
            + "(volume unmounted, or Full Disk Access not granted to this app)")
    }

    if available && !poller.isRunning {
        let fsEventsStarted = watcher.start()
        poller.start()
        logger.log("watching \(config.targetPath) "
            + "(fsevents: \(fsEventsStarted ? "on" : "unavailable"), "
            + "poll: \(Int(Config.pollIntervalSeconds))s)")
        runner.run(reason: "watch-start reconcile")
        return
    }

    if !available && poller.isRunning {
        watcher.stop()
        poller.stop()
        logger.log("target unavailable, watchers stopped: \(config.targetPath)")
    }
}

let supervisorTimer = DispatchSource.makeTimerSource(queue: eventQueue)
supervisorTimer.schedule(deadline: .now(), repeating: Config.supervisorIntervalSeconds)
supervisorTimer.setEventHandler { superviseWatcher() }
supervisorTimer.resume()

let sweepTimer = DispatchSource.makeTimerSource(queue: eventQueue)
sweepTimer.schedule(deadline: .now() + Config.sweepIntervalSeconds, repeating: Config.sweepIntervalSeconds)
sweepTimer.setEventHandler {
    guard targetExists() else { return }
    runner.run(reason: "periodic sweep")
}
sweepTimer.resume()

signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: eventQueue)
terminationSource.setEventHandler {
    logger.log("SIGTERM received, shutting down")
    watcher.stop()
    poller.stop()
    exit(0)
}
terminationSource.resume()

logger.log("agent started (pid \(ProcessInfo.processInfo.processIdentifier)), target: \(config.targetPath)")
dispatchMain()
