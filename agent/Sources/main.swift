import Darwin
import Dispatch

// Persistent agent for the Downloads Organizer.
//
// Replaces the AppleScript applet that launchd used to relaunch every 60s. One
// long-lived process means the TCC grant is negotiated once at launch instead
// of 1440 times a day, which is what made permission prompts recur endlessly.
//
// Deliberately links neither Foundation nor CoreFoundation: everything it does
// is a timestamp, two small file reads, a stat and a spawn, all of which libc
// provides for a fraction of the resident memory.

let config = Config.resolve()
let log = Log(path: config.logPath)
let runner = WorkerRunner(config: config, log: log)

// One serial queue carries the poller, the supervisor, the sweep and the
// debounce. The worker gets its own queue because it blocks on waitpid and
// would otherwise stall every timer above.
let eventQueue = DispatchQueue(label: "local.organize-downloads.events")
var pendingRun: DispatchWorkItem?

/// Collapses a burst of changes into a single worker run once the folder has
/// been quiet for `debounceSeconds`.
func scheduleDebouncedRun() {
    pendingRun?.cancel()
    let work = DispatchWorkItem { runner.run(reason: "change detected") }
    pendingRun = work
    eventQueue.asyncAfter(deadline: .now() + Config.debounceSeconds, execute: work)
}

let poller = DirectoryPoller(path: config.targetPath, queue: eventQueue) {
    scheduleDebouncedRun()
}

func targetExists() -> Bool { Posix.isDirectory(config.targetPath) }

/// `reportedUnavailable` keeps the "can't see the target" message to once per
/// outage instead of once every supervisor tick.
var reportedUnavailable = false

/// Keeps the poller in step with the target's availability. The target can live
/// on a removable volume, so it legitimately comes and goes.
func superviseTarget() {
    let available = targetExists()

    if available {
        reportedUnavailable = false
    } else if !reportedUnavailable {
        reportedUnavailable = true
        log.write("target not reachable: \(config.targetPath) "
            + "(volume unmounted, or Full Disk Access not granted to this app)")
    }

    if available && !poller.isRunning {
        poller.start()
        log.write("watching \(config.targetPath) (poll: \(Int(Config.pollIntervalSeconds))s)")
        runner.run(reason: "start reconcile")
        return
    }

    if !available && poller.isRunning {
        poller.stop()
        log.write("target unavailable, poller stopped: \(config.targetPath)")
    }
}

let supervisorTimer = DispatchSource.makeTimerSource(queue: eventQueue)
supervisorTimer.schedule(
    deadline: .now(),
    repeating: Config.supervisorIntervalSeconds,
    leeway: .seconds(5)
)
supervisorTimer.setEventHandler { superviseTarget() }
supervisorTimer.resume()

let sweepTimer = DispatchSource.makeTimerSource(queue: eventQueue)
sweepTimer.schedule(
    deadline: .now() + Config.sweepIntervalSeconds,
    repeating: Config.sweepIntervalSeconds,
    leeway: .seconds(30)
)
sweepTimer.setEventHandler {
    guard targetExists() else { return }
    runner.run(reason: "periodic sweep")
}
sweepTimer.resume()

signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: eventQueue)
terminationSource.setEventHandler {
    log.write("SIGTERM received, shutting down")
    poller.stop()
    exit(0)
}
terminationSource.resume()

log.write("agent started (pid \(getpid())), target: \(config.targetPath)")
dispatchMain()
