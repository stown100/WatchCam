import Foundation

/// Recordings kept on the watch until WatchConnectivity confirms the phone received them.
/// Each recording is `<session>.caf` plus `<session>.json` with its metadata.
enum PendingRecordings {
    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func audioURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).caf")
    }

    private static func infoURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func save(_ info: WatchRecordingInfo) {
        try? JSONEncoder().encode(info).write(to: infoURL(for: info.sessionID), options: .atomic)
    }

    static func all() -> [WatchRecordingInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(WatchRecordingInfo.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: audioURL(for: $0.sessionID).path) }
    }

    static func remove(_ sessionID: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: sessionID))
        try? FileManager.default.removeItem(at: infoURL(for: sessionID))
    }

    /// Deletes audio files that never got metadata (the app died mid-recording and the file is unusable for sync).
    static func removeOrphans(except active: UUID?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "caf" {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            guard id != active, let id, !FileManager.default.fileExists(atPath: infoURL(for: id).path) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
