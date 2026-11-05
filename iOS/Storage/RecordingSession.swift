import Foundation
import SyncKit

/// One take: iPhone video + (optionally) watch audio, and everything learned about them.
/// Stored as `session.json` in the session's folder so it survives app restarts.
struct RecordingSession: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording
        case waitingForWatch
        case processing
        case ready
        case saved
        case failed

        var title: String {
            switch self {
            case .recording: "Записывается"
            case .waitingForWatch: "Ждём звук с часов"
            case .processing: "Синхронизация…"
            case .ready: "Синхронизировано"
            case .saved: "Сохранено"
            case .failed: "Ошибка"
            }
        }
    }

    var id: UUID
    var createdAt: Date
    var status: Status
    /// The watch was recording too (otherwise this is an iPhone-only take).
    var usesWatch: Bool
    var captureSummary: String
    var frameRate: Int

    // iPhone video
    var videoStartHostTime: Double?
    var videoStartWallTime: Date?
    /// `true` when the start time is the first frame's timestamp (iOS 18.2+),
    /// `false` when it's the time of the "did start" callback.
    var videoStartIsPrecise = false
    var videoDuration: Double?
    var videoFinished = false

    // Watch audio
    var watchInfo: WatchRecordingInfo?
    var watchAudioFileName: String?
    /// Watch audio resampled to cancel clock drift, if the drift was large enough.
    var correctedAudioFileName: String?
    /// The watch recorded only part of the take: a track for the whole video, using the iPhone's
    /// own sound where the watch has none. Lines up with the video from its first frame.
    var filledAudioFileName: String?
    /// How much of the video that track takes from the iPhone, in seconds.
    var filledAudioSeconds: Double?

    // Sync
    var sync: SyncResult?
    var coarseOffset: Double?
    /// User correction on top of the automatic offset, seconds.
    var manualOffset: Double = 0

    var savedAt: Date?
    /// Auto-save runs once per session, even if it fails (e.g. no Photos access).
    var autoSaveAttempted = false
    var sourcesDeleted = false
    var errorMessage: String?

    var hasWatchAudio: Bool { watchAudioFileName != nil }
}
