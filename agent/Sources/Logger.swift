import Foundation

/// Append-only logger with size-based rotation. The agent keeps its own log
/// separate from the worker's so a stuck watcher is distinguishable from a
/// worker that ran and found nothing to do.
final class Logger {
    private let path: String
    private let queue = DispatchQueue(label: "local.organize-downloads.log")
    private let formatter: ISO8601DateFormatter

    init(path: String) {
        self.path = path
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.formatter = formatter
    }

    func log(_ message: String) {
        queue.async { [self] in
            let line = "\(formatter.string(from: Date())) [agent] \(message)\n"
            rotateIfNeeded()
            append(line)
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int, size > Config.maxLogBytes else { return }
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
}
