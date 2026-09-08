import Foundation

/// Runs the bash worker as a child of this app.
///
/// Keeping the worker as a child is deliberate: TCC attributes the child's file
/// access to its responsible process, which is this bundle. The app holds the
/// Full Disk Access grant, so the script inherits it without needing one of its
/// own. Runs are serialised so a slow sweep can never overlap the next trigger.
final class WorkerRunner {
    private let config: Config
    private let logger: Logger
    private let queue = DispatchQueue(label: "local.organize-downloads.worker")
    private var isRunning = false

    init(config: Config, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    func run(reason: String) {
        queue.async { [self] in
            guard !isRunning else {
                logger.log("skipped (\(reason)): a run is already in progress")
                return
            }
            isRunning = true
            defer { isRunning = false }
            execute(reason: reason)
        }
    }

    private func execute(reason: String) {
        guard FileManager.default.isExecutableFile(atPath: config.workerPath) else {
            logger.log("worker missing or not executable: \(config.workerPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [config.workerPath]

        var environment = ProcessInfo.processInfo.environment
        environment["ORGANIZE_DL"] = config.targetPath
        process.environment = environment

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            logger.log("worker failed to launch: \(error.localizedDescription)")
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            logger.log("worker exited \(process.terminationStatus) (\(reason))")
        }
        let stderr = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            logger.log("worker stderr: \(stderr.suffix(500))")
        }
    }
}
