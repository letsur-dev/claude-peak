import Foundation

@MainActor
final class ActivityMonitor: ObservableObject {
    @Published var tokensPerSecond: Double = 0

    private let claudeDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileHandles: [URL: UInt64] = [:] // file -> last read offset
    private var recentTokens: [(date: Date, tokens: Int)] = []
    private var scanTimer: Timer?

    init() {
        claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func start() {
        // Scan every 2 seconds for new tokens in JSONL files
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanForNewTokens()
            }
        }
        scanForNewTokens()
    }

    func stop() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func scanForNewTokens() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: claudeDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-60) // only check files modified in last 60s

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // Only process recently modified files
            if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modDate < cutoff {
                continue
            }

            readNewLines(from: fileURL)
        }

        // Clean old entries (older than 30 seconds)
        let windowStart = Date().addingTimeInterval(-30)
        recentTokens.removeAll { $0.date < windowStart }

        recalculate()
    }

    private func recalculate() {
        let total = recentTokens.reduce(0) { $0 + $1.tokens }
        let window: Double = 30
        tokensPerSecond = Double(total) / window
        Log.info("TPS: \(Int(tokensPerSecond)) (tokens: \(total))")
    }

    private func readNewLines(from url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fileHandle.close() }

        let lastOffset = fileHandles[url] ?? {
            // First time seeing this file: seek to end (only read new data)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return size
        }()

        fileHandle.seek(toFileOffset: lastOffset)
        let newData = fileHandle.readDataToEndOfFile()
        let currentOffset = fileHandle.offsetInFile
        fileHandles[url] = currentOffset

        guard !newData.isEmpty,
              let text = String(data: newData, encoding: .utf8) else { return }

        let now = Date()
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
            let total = input + output + cacheRead + cacheCreate

            if total > 0 {
                recentTokens.append((date: now, tokens: total))
            }
        }
    }
}
