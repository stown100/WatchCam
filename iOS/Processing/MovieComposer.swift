import AVFoundation
import SyncKit
import UIKit
import os

/// Builds the final movie: iPhone video + watch audio shifted by the sync offset.
///
/// AVMutableComposition is an "edit list": it references time ranges of the source files
/// without copying them, so it can be played immediately and exported without re-encoding.
enum MovieComposer {
    enum ComposerError: LocalizedError {
        case noVideoTrack
        case noAudioTrack
        case noOverlap
        case exportFailed(String)
        /// iOS paused the export because the app left the screen. The file itself is fine.
        case interrupted

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "В видеофайле нет видеодорожки."
            case .noAudioTrack: "В файле с часов нет звука."
            case .noOverlap: "Видео и звук с часов не пересекаются по времени."
            case .exportFailed(let reason): "Экспорт не удался: \(reason)"
            case .interrupted: "Экспорт прервался, потому что приложение было свёрнуто. Нажмите кнопку ещё раз."
            }
        }
    }

    struct AudioSource {
        var url: URL
        /// `audioTime - videoTime`, seconds.
        var offset: Double
    }

    private static let logger = Logger(subsystem: "WatchCam", category: "Composer")
    private static let timescale: CMTimeScale = 48_000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// - Parameters:
    ///   - audio: external audio to put under the video; `nil` keeps the iPhone's own sound.
    ///   - keepPhoneAudio: also keep the iPhone audio as a second, disabled track.
    static func makeComposition(videoURL: URL, audio: AudioSource?, keepPhoneAudio: Bool) async throws -> AVMutableComposition {
        let videoAsset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ComposerError.noVideoTrack
        }
        let phoneAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first
        let (videoRange, transform) = try await videoTrack.load(.timeRange, .preferredTransform)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noVideoTrack
        }
        // Orientation recorded by the camera lives in the track transform.
        compositionVideo.preferredTransform = transform

        guard let audio else {
            try compositionVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)
            if let phoneAudioTrack, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(try await phoneAudioTrack.load(.timeRange), of: phoneAudioTrack, at: .zero)
            }
            return composition
        }

        let audioAsset = AVURLAsset(url: audio.url)
        guard let watchTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ComposerError.noAudioTrack
        }
        let audioRange = try await watchTrack.load(.timeRange)
        guard let plan = MergePlanner.plan(
            video: videoRange.start.seconds...videoRange.end.seconds,
            audio: audioRange.start.seconds...audioRange.end.seconds,
            offset: audio.offset
        ) else { throw ComposerError.noOverlap }

        let videoPart = CMTimeRange(start: time(plan.videoStart), duration: time(plan.duration))
        let audioPart = CMTimeRange(start: time(plan.audioStart), duration: time(plan.duration))
        try compositionVideo.insertTimeRange(videoPart, of: videoTrack, at: .zero)

        guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noAudioTrack
        }
        try compositionAudio.insertTimeRange(audioPart, of: watchTrack, at: .zero)

        if keepPhoneAudio, let phoneAudioTrack,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(videoPart, of: phoneAudioTrack, at: .zero)
            // Players use the watch track; editors still see this one.
            track.isEnabled = false
        }
        return composition
    }

    /// Exports without re-encoding (passthrough keeps full quality and HDR). Falls back to the
    /// best HEVC preset only if passthrough isn't possible.
    static func export(_ asset: AVAsset, to url: URL, creationDate: Date) async throws {
        try? FileManager.default.removeItem(at: url)
        do {
            try await run(asset, preset: AVAssetExportPresetPassthrough, to: url, creationDate: creationDate)
        } catch ComposerError.interrupted {
            // Not a format problem: re-encoding would only lose quality. It has to run again later.
            try? FileManager.default.removeItem(at: url)
            throw ComposerError.interrupted
        } catch {
            logger.error("Passthrough export failed (\(error.localizedDescription, privacy: .public)), re-encoding")
            try? FileManager.default.removeItem(at: url)
            try await run(asset, preset: AVAssetExportPresetHEVCHighestQuality, to: url, creationDate: creationDate)
        }
    }

    private static func run(_ asset: AVAsset, preset: String, to url: URL, creationDate: Date) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ComposerError.exportFailed("preset \(preset) unavailable")
        }
        session.metadata = metadata(creationDate: creationDate)
        session.shouldOptimizeForNetworkUse = false
        do {
            if #available(iOS 18.0, *) {
                try await session.export(to: url, as: .mov)
            } else {
                session.outputURL = url
                session.outputFileType = .mov
                await session.export()
                guard session.status == .completed else {
                    throw session.error ?? ComposerError.exportFailed("status \(session.status.rawValue)")
                }
            }
        } catch {
            if await wasInterrupted(by: error) { throw ComposerError.interrupted }
            throw error
        }
    }

    private static func wasInterrupted(by error: Error) async -> Bool {
        let code = (error as? AVError)?.code
        if code == .operationInterrupted || code == .mediaServicesWereReset { return true }
        return await UIApplication.shared.applicationState != .active
    }

    /// Keeps the original shooting date, so Photos sorts the clip correctly.
    private static func metadata(creationDate: Date) -> [AVMetadataItem] {
        let value = ISO8601DateFormatter().string(from: creationDate) as NSString
        return [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate].map { identifier in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            return item
        }
    }
}
