import Foundation
import os

/// Voice-mode diagnostics: the system log, plus a small file in Caches that can be pulled from a
/// device (`devicectl device copy from … Library/Caches/voice.log`) when a session misbehaves.
enum VoiceLog {
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "Voice")
    private static let queue = DispatchQueue(label: "com.artemis.ios.voicelog")
    private static let maxSize = 256 * 1024

    static let fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice.log")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int, size > maxSize {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
