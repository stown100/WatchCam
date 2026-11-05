import Foundation
import Observation

/// Keeps recording sessions on disk: `Application Support/Sessions/<id>/session.json`
/// next to that session's media files.
@MainActor @Observable
final class SessionStore {
    /// Newest first.
    private(set) var sessions: [RecordingSession] = []

    nonisolated static let rootDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sessions", isDirectory: true)
    }()

    nonisolated static func directory(for id: UUID) -> URL {
        let url = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func videoURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("video.mov")
    }

    nonisolated static func watchAudioURL(for id: UUID, fileExtension: String) -> URL {
        directory(for: id).appendingPathComponent("watch.\(fileExtension)")
    }

    nonisolated static func fileURL(for id: UUID, name: String) -> URL {
        directory(for: id).appendingPathComponent(name)
    }

    private nonisolated static func metadataURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("session.json")
    }

    init() {
        load()
    }

    func session(_ id: UUID) -> RecordingSession? {
        sessions.first { $0.id == id }
    }

    func insert(_ session: RecordingSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        persist(session)
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout RecordingSession) -> Void) -> RecordingSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        change(&sessions[index])
        persist(sessions[index])
        return sessions[index]
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.rootDirectory.appendingPathComponent(id.uuidString))
    }

    /// Total size of a session's files, for the library.
    func diskUsage(of id: UUID) -> Int64 {
        let folder = Self.rootDirectory.appendingPathComponent(id.uuidString)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.rootDirectory, includingPropertiesForKeys: nil)) ?? []
        sessions = folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
                return try? JSONDecoder().decode(RecordingSession.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func persist(_ session: RecordingSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: Self.metadataURL(for: session.id), options: .atomic)
    }
}
