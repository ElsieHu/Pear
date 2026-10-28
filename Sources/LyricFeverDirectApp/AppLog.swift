import Foundation
import os

/// Tiny append-only file logger.
///
/// The app runs as a menu-bar agent with no console, so when something goes
/// wrong (no automation permission, lyrics cache missing, …) the only way to
/// see what happened is a log file. Also surfaced in the menu-bar panel under
/// “诊断日志”.
enum AppLog {
    static let fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LyricFeverDirect.log")
    }()

    private static let queue = DispatchQueue(label: "LyricFeverDirect.log")
    private static let maxBytes = 256 * 1024

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] \(message)\n"
        queue.async {
            // `forWritingAtPath` truncates — it would wipe every previous
            // line, making the log look like nothing ever ran. `forUpdating`
            // opens O_RDWR (no truncate) so we can genuinely append.
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let handle = FileHandle(forUpdatingAtPath: fileURL.path) else {
                try? line.data(using: .utf8)?.write(to: fileURL)
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)??.intValue ?? 0
            if size > maxBytes { trim() }
            try? handle.close()
        }
        #if DEBUG
        print("LyricFeverDirect [\(level)] \(message)")
        #endif
    }

    /// Keep the newest ~half of the file so it never grows without bound.
    private static func trim() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        let keep = lines.suffix(max(50, lines.count / 2))
        try? keep.joined(separator: "\n").appending("\n").data(using: .utf8)?.write(to: fileURL)
    }

    /// Last N lines — used by the “诊断日志” popover.
    static func tail(_ count: Int = 40) -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "（暂无日志）"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(count).joined(separator: "\n")
    }
}
