import Foundation
import os

/// A short diary of what happens around a recording, kept on the watch's disk.
///
/// When watchOS suspends or ends an app, nothing is left to look at afterwards. These lines
/// survive that, and a hole between their times shows when the app wasn't running.
/// Read it from the Mac with `xcrun devicectl device copy from`: see the README.
enum Journal {
    private static let logger = Logger(subsystem: "WatchCam", category: "Journal")
    private static let queue = DispatchQueue(label: "WatchCam.Journal")
    private static let maximumSize: UInt64 = 256_000

    private static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let fileURL = directory.appendingPathComponent("journal.log")
    private static let lockProbeURL = directory.appendingPathComponent("lock-probe")

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let date = Date()
        queue.async {
            let data = Data("\(timeFormatter.string(from: date)) \(message)\n".utf8)
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                // The diary has to stay writable on a locked watch: that's what it is for.
                try? data.write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                return
            }
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > maximumSize {
                let old = directory.appendingPathComponent("journal.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: fileURL, to: old)
                try? data.write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                return
            }
            try? handle.write(contentsOf: data)
        }
    }

    /// Prepares `isLocked`. Writing needs the watch unlocked, so it may have to wait for a later launch.
    static func prepareLockProbe() {
        guard !FileManager.default.fileExists(atPath: lockProbeURL.path) else { return }
        try? Data([1]).write(to: lockProbeURL, options: .completeFileProtection)
    }

    /// Judged by a file that can only be read while the watch is unlocked. `nil` means unknown.
    static var isLocked: Bool? {
        guard FileManager.default.fileExists(atPath: lockProbeURL.path) else { return nil }
        return (try? Data(contentsOf: lockProbeURL)) == nil
    }
}
