import AVFoundation
import Foundation

/// Recordings kept on the watch until WatchConnectivity confirms the phone received them.
///
/// Each recording is `<session>.caf`, plus `<session>.json` with its metadata once it's finished.
/// While it's in progress, `<session>.checkpoint` holds the same metadata as of a few seconds ago,
/// so the audio is still usable if the app dies.
enum PendingRecordings {
    /// Survives the watch locking: only the first unlock after a restart is needed.
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }()

    static func audioURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).caf")
    }

    private static func infoURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func checkpointURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).checkpoint")
    }

    /// The recording is finished: from now on it only waits for its trip to the phone.
    static func save(_ info: WatchRecordingInfo) {
        try? JSONEncoder().encode(info).write(to: infoURL(for: info.sessionID), options: writeOptions)
        try? FileManager.default.removeItem(at: checkpointURL(for: info.sessionID))
    }

    static func saveCheckpoint(_ info: WatchRecordingInfo) {
        try? JSONEncoder().encode(info).write(to: checkpointURL(for: info.sessionID), options: writeOptions)
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
        try? FileManager.default.removeItem(at: checkpointURL(for: sessionID))
    }

    /// Replaces a finished PCM recording with AAC.
    /// - Returns: the new metadata, or `nil` if the recording stays as it was.
    static func compress(_ info: WatchRecordingInfo) -> WatchRecordingInfo? {
        let temporary = directory.appendingPathComponent("\(info.sessionID.uuidString)-compressing.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard try AudioRecorder.compressToAAC(input: audioURL(for: info.sessionID), output: temporary) else { return nil }
            _ = try FileManager.default.replaceItemAt(audioURL(for: info.sessionID), withItemAt: temporary)
        } catch {
            Journal.log("compression failed, sending PCM: \(error.localizedDescription)")
            return nil
        }
        var compressed = info
        compressed.format = .aac
        save(compressed)
        return compressed
    }

    /// Picks up what a recording left behind if the app died while it was running.
    ///
    /// - Returns: recordings made ready to send, and takes with nothing usable left.
    static func recoverInterrupted() -> (recovered: [WatchRecordingInfo], lost: [UUID]) {
        var recovered: [WatchRecordingInfo] = []
        var lost: [UUID] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "caf" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                // Left over from a compression that didn't finish. The original is still there.
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard !FileManager.default.fileExists(atPath: infoURL(for: id).path) else { continue }

            if var info = (try? Data(contentsOf: checkpointURL(for: id))).flatMap({ try? JSONDecoder().decode(WatchRecordingInfo.self, from: $0) }),
               let source = try? AVAudioFile(forReading: file), source.length > 0 {
                // The file itself tells how far the recording got, more exactly than the checkpoint.
                info.duration = Double(source.length) / source.processingFormat.sampleRate
                info.wasInterrupted = true
                save(info)
                recovered.append(info)
            } else {
                remove(id)
                lost.append(id)
            }
        }
        return (recovered, lost)
    }
}
