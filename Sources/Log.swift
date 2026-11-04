import Foundation

/// Appends one line to ~/Library/Logs/ScreenshotTool.log. Never logs image content.
enum Log {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenshotTool.log")
    private static let queue = DispatchQueue(label: "log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }
}
