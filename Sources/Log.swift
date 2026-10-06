// Log.swift: one line per event in ~/Library/Logs/Squelch.log, written off the main thread.
import Foundation

enum Log {
    // SQUELCH_LOG points the test harnesses somewhere else.
    static let url = ProcessInfo.processInfo.environment["SQUELCH_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Squelch.log")
    private static let queue = DispatchQueue(label: "io.forit.squelch.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func i(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// Milliseconds since t0, for the press latency lines.
func msSince(_ t0: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
}
