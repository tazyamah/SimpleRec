import Foundation

/// Lightweight append-only logger. Writes to <outputFolder>/SimpleRec_log.txt
/// and also mirrors to stderr. Thread-safe (used from main + audio threads).
final class RecLog: @unchecked Sendable {
    static let shared = RecLog()

    private let lock = NSLock()
    private var url: URL?
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Point the log at a folder. Starts a fresh session marker.
    func configure(folder: URL) {
        lock.lock(); defer { lock.unlock() }
        let u = folder.appendingPathComponent("SimpleRec_log.txt")
        url = u
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil)
        }
        write("==================== session start ====================")
    }

    func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        write(message)
    }

    // must be called with lock held
    private func write(_ message: String) {
        let line = "[\(df.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        guard let u = url else { return }
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }
}
