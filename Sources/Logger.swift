import Foundation

enum Log {
    private static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-peak")
    private static let logFile = logDir.appendingPathComponent("debug.log")
    private static let maxSize: UInt64 = 1_000_000 // 1MB

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        // Rotate if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > maxSize {
            let backup = logDir.appendingPathComponent("debug.log.1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: logFile, to: backup)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        }
    }
}
