import Darwin
import Dispatch

// Persistent agent for the Downloads Organizer.
//
// Replaces the AppleScript applet that launchd used to relaunch every 60s. One
// long-lived process means the TCC grant is negotiated once at launch instead
// of 1440 times a day, which is what made permission prompts recur endlessly.
//
// Watches up to two folders: the target being organised, and an optional
// inbox the worker drains into the target first (for the setup where browsers
// save to an external volume while other apps still write to ~/Downloads).
// Both use the same mtime poller and feed the same debounce.
//
// Deliberately links neither Foundation nor CoreFoundation: everything it does
// is a timestamp, a few small file reads, a stat and a spawn, all of which
// libc provides for a fraction of the resident memory.

let config = Config.resolve()
let log = Log(path: config.logPath)
let runner = WorkerRunner(config: config, log: log)

// One serial queue carries the pollers, the supervisor, the sweep and the
// debounce. The worker gets its own queue because it blocks on waitpid and
// would otherwise stall every timer above.
let eventQueue = DispatchQueue(label: "local.organize-downloads.events")
var pendingRun: DispatchWorkItem?

/// One pending run at a time: a new schedule replaces whatever was waiting,
/// so a burst of changes, or a retry overtaken by a change, still ends in a
/// single run once the folders have been quiet.
func scheduleRun(after delay: Double, reason: String) {
    pendingRun?.cancel()
    let work = DispatchWorkItem { runner.run(reason: reason) }
    pendingRun = work
    eventQueue.asyncAfter(deadline: .now() + delay, execute: work)
}

/// Collapses a burst of changes into a single worker run once the folders
/// have been quiet for `debounceSeconds`.
func scheduleDebouncedRun() {
    scheduleRun(after: Config.debounceSeconds, reason: "change detected")
}

/// The worker exits `workerDeferredExitCode` when it skipped entries that
/// were still being written. An app saving in place (no temp name) changes
/// the folder's mtime once, at creation, so nothing would wake the poller
/// again when it finishes; poll it back on a short backoff instead of leaving
/// it to the periodic sweep.
var retryDelay = Config.retryInitialSeconds

func handleWorkerExit(_ code: Int32) {
    guard code == Config.workerDeferredExitCode else {
        retryDelay = Config.retryInitialSeconds
        return
    }
    log.write("worker deferred entries still being written, retrying in \(Int(retryDelay))s")
    scheduleRun(after: retryDelay, reason: "retry deferred")
    retryDelay = min(retryDelay * 2, Config.retryMaxSeconds)
}
runner.onExit = { code in eventQueue.async { handleWorkerExit(code) } }

let targetPoller = DirectoryPoller(path: config.targetPath, queue: eventQueue) {
    scheduleDebouncedRun()
}
let inboxPoller: DirectoryPoller? = config.inboxPath.map { path in
    DirectoryPoller(path: path, queue: eventQueue) { scheduleDebouncedRun() }
}

func targetExists() -> Bool { Posix.isDirectory(config.targetPath) }

/// The `reported…` flags keep each "can't see the folder" message to once per
/// outage instead of once every supervisor tick.
var reportedUnavailable = false
var reportedInboxMissing = false

/// Keeps the pollers in step with the target's availability. The target can
/// live on a removable volume, so it legitimately comes and goes.
func superviseTarget() {
    let available = targetExists()

    if available {
        reportedUnavailable = false
    } else if !reportedUnavailable {
        reportedUnavailable = true
        log.write("target not reachable: \(config.targetPath) "
            + "(volume unmounted, or Full Disk Access not granted to this app)")
    }

    if available && !targetPoller.isRunning {
        targetPoller.start()
        log.write("watching \(config.targetPath) (poll: \(Int(Config.pollIntervalSeconds))s)")
        runner.run(reason: "start reconcile")
    }

    if !available && targetPoller.isRunning {
        targetPoller.stop()
        log.write("target unavailable, poller stopped: \(config.targetPath)")
    }

    superviseInbox(targetAvailable: available)
}

/// The inbox is only worth watching while the target can receive from it: a
/// change there with the volume unplugged would trigger a run that aborts.
/// Whatever accumulates is relayed by the reconcile run when the target
/// comes back.
func superviseInbox(targetAvailable: Bool) {
    guard let poller = inboxPoller, let inbox = config.inboxPath else { return }
    let inboxExists = Posix.isDirectory(inbox)

    if inboxExists {
        reportedInboxMissing = false
    } else if targetAvailable && !reportedInboxMissing {
        reportedInboxMissing = true
        log.write("inbox not reachable: \(inbox)")
    }

    let shouldWatch = targetAvailable && inboxExists
    if shouldWatch && !poller.isRunning {
        poller.start()
        log.write("relaying \(inbox) -> \(config.targetPath)")
    } else if !shouldWatch && poller.isRunning {
        poller.stop()
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
    targetPoller.stop()
    inboxPoller?.stop()
    exit(0)
}
terminationSource.resume()

log.write("agent started (pid \(getpid())), target: \(config.targetPath), "
    + "inbox: \(config.inboxPath ?? "none")")
dispatchMain()
