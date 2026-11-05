import AVFoundation
import Foundation
import Observation
import SyncKit
import UIKit
import os

/// Turns finished takes into clips: sync → composition → export → Photos.
@MainActor @Observable
final class SessionProcessor {
    enum ProcessingError: LocalizedError {
        case busy

        var errorDescription: String? { "Подождите: эта запись ещё обрабатывается." }
    }

    /// Sessions with work in progress (sync, export, save), for spinners.
    /// One job per session at a time: exports of the same take write to the same file.
    private(set) var busy: Set<UUID> = []

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let logger = Logger(subsystem: "WatchCam", category: "Processor")
    /// Counts departures from the screen. A job that failed after one of them was probably cut
    /// short by iOS, which says nothing about the recording.
    @ObservationIgnored private var backgroundEntries = 0

    init(store: SessionStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        removeLeftoverExports()
    }

    /// Temporary copies left behind if the app was killed during an export. Sources stay.
    private func removeLeftoverExports() {
        for session in store.sessions {
            try? FileManager.default.removeItem(at: SessionStore.fileURL(for: session.id, name: Self.clipFileName(for: session)))
            try? FileManager.default.removeItem(at: Self.sourcesExportFolder(for: session.id))
        }
    }

    func appDidEnterBackground() {
        backgroundEntries += 1
    }

    /// Picks up everything that can move forward (call at launch and when new files arrive).
    func processPending() {
        for session in store.sessions { processIfReady(session.id) }
    }

    func processIfReady(_ id: UUID) {
        guard let session = store.session(id), session.videoFinished, !busy.contains(id) else { return }
        switch session.status {
        case .waitingForWatch, .processing:
            guard session.hasWatchAudio else { return }
            busy.insert(id)
            Task {
                let finished = await withBackgroundTime("Sync") { await synchronize(id) }
                busy.remove(id)
                if finished {
                    await autoSaveIfNeeded(id)
                } else {
                    retryIfOnScreen(id)
                }
            }
        case .ready:
            Task { await autoSaveIfNeeded(id) }
        case .recording, .saved, .failed:
            break
        }
    }

    // MARK: - Background time

    /// Asks iOS for extra time (usually about 30 s) to finish a job if the user leaves the app.
    private func withBackgroundTime<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let time = BackgroundTime(name: name)
        defer { time.end() }
        return try await work()
    }

    /// The app may already be back on screen when a job reports that iOS interrupted it.
    /// Otherwise `processPending` picks the session up on return.
    private func retryIfOnScreen(_ id: UUID) {
        if UIApplication.shared.applicationState == .active { processIfReady(id) }
    }

    // MARK: - Sync

    /// - Returns: `false` if iOS cut the work short: the session stays `.processing` for another try.
    private func synchronize(_ id: UUID) async -> Bool {
        guard let session = store.update(id, { $0.status = .processing; $0.errorMessage = nil }),
              let audioName = session.watchAudioFileName else { return true }
        let videoURL = SessionStore.videoURL(for: id)
        let audioURL = SessionStore.fileURL(for: id, name: audioName)
        let coarse = Self.coarseOffset(for: session)
        logger.info("Sync \(id, privacy: .public): coarse offset \(coarse ?? .nan, format: .fixed(precision: 4)) s")
        let entries = backgroundEntries

        // Inserted silence can't be aligned with anything: analyze the longest stretch of real sound.
        let soundSpan = session.watchInfo.flatMap { info -> ClosedRange<Double>? in
            guard let gaps = info.gaps else { return nil }
            return AudioCoverage.longestSoundSpan(audioDuration: info.duration, gaps: gaps.map { $0.start...($0.start + $0.duration) })
        }

        let result: SyncResult
        do {
            result = try await SyncEngine.synchronize(reference: videoURL, target: audioURL, coarseOffset: coarse, soundSpan: soundSpan)
        } catch {
            // Typically: the video has no iPhone audio (microphone access denied).
            logger.error("Fine sync failed: \(error.localizedDescription, privacy: .public)")
            result = SyncResult(method: .coarse, offset: coarse ?? 0, ratio: 1, confidence: 0, windows: [])
        }
        for window in result.windows {
            logger.info("  window @\(window.referenceTime, format: .fixed(precision: 1)) s: offset \(window.offset, format: .fixed(precision: 4)) s, z \(window.zScore, format: .fixed(precision: 1)), ratio \(window.peakRatio, format: .fixed(precision: 2)), reliable \(window.isReliable)")
        }
        logger.info("Result: \(result.method.rawValue, privacy: .public), offset \(result.offset, format: .fixed(precision: 4)) s, drift \(result.driftPPM, format: .fixed(precision: 1)) ppm")

        // Reading audio stops when the app leaves the screen: don't settle for "approximate" because of that.
        if result.isApproximate, backgroundEntries != entries {
            logger.info("Sync was interrupted by leaving the app, will run again")
            return false
        }

        let corrected = await correctDriftIfNeeded(session, result: result, audioURL: audioURL)

        var filled: FilledAudio?
        var fillError: String?
        do {
            filled = try await fillMissingAudioIfNeeded(session, result: result, audioURL: audioURL, corrected: corrected)
        } catch {
            if backgroundEntries != entries {
                logger.info("Filling was interrupted by leaving the app, will run again")
                return false
            }
            logger.error("Filling missing audio failed: \(error.localizedDescription, privacy: .public)")
            // The clip is then cut to the part the watch recorded. The full video stays in the record.
            fillError = "Часы записали только часть, и дополнить звук не удалось: ролик будет короче видео."
        }

        store.update(id) {
            $0.sync = result
            $0.coarseOffset = coarse
            $0.correctedAudioFileName = corrected
            $0.filledAudioFileName = filled?.name
            $0.filledAudioSeconds = filled?.seconds
            $0.errorMessage = fillError
            $0.status = .ready
        }
        return true
    }

    private struct FilledAudio {
        var name: String
        var seconds: Double
    }

    /// The watch may have recorded only part of the take. The video stays whole, with the iPhone's
    /// own sound where the watch has none.
    private func fillMissingAudioIfNeeded(
        _ session: RecordingSession,
        result: SyncResult,
        audioURL: URL,
        corrected: String?
    ) async throws -> FilledAudio? {
        guard let info = session.watchInfo, let duration = session.videoDuration else { return nil }

        // Drift correction stretches the file's timeline by 1/ratio.
        let scale = corrected == nil ? 1 : result.ratio
        let source = corrected.map { SessionStore.fileURL(for: session.id, name: $0) } ?? audioURL
        let offset = result.offset / scale
        let gaps = (info.gaps ?? []).map { ($0.start / scale)...(($0.start + $0.duration) / scale) }

        let missing = AudioCoverage.missing(videoDuration: duration, audioDuration: info.duration / scale, gaps: gaps, offset: offset)
        guard !missing.isEmpty else { return nil }

        let seconds = missing.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        logger.info("Watch audio covers only part of the take: \(seconds, format: .fixed(precision: 1)) s to fill from the iPhone")
        let name = "watch-filled.caf"
        try await AudioFileTools.fillMissing(
            watch: source, offset: offset, missing: missing,
            video: SessionStore.videoURL(for: session.id), videoDuration: duration,
            output: SessionStore.fileURL(for: session.id, name: name))
        return FilledAudio(name: name, seconds: seconds)
    }

    /// Long takes: the watch's audio clock runs slightly faster or slower than the iPhone's.
    /// If the accumulated difference exceeds one video frame, resample the watch audio to match.
    private func correctDriftIfNeeded(_ session: RecordingSession, result: SyncResult, audioURL: URL) async -> String? {
        guard result.method == .crossCorrelation, let duration = session.videoDuration else { return nil }
        let driftAtEnd = abs(result.ratio - 1) * duration
        let frame = 1 / Double(max(session.frameRate, 1))
        guard driftAtEnd > frame else { return nil }

        let name = "watch-corrected.caf"
        let output = SessionStore.fileURL(for: session.id, name: name)
        let ratio = result.ratio
        do {
            try await Task.detached(priority: .userInitiated) {
                try AudioFileTools.timeScale(input: audioURL, output: output, ratio: ratio)
            }.value
            logger.info("Drift \(result.driftPPM, format: .fixed(precision: 1)) ppm (\(driftAtEnd * 1000, format: .fixed(precision: 0)) ms over the take): watch audio resampled")
            return name
        } catch {
            logger.error("Drift correction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Clock-based estimate of `watchAudioTime - videoTime`, before any audio analysis.
    static func coarseOffset(for session: RecordingSession) -> Double? {
        guard let info = session.watchInfo else { return nil }
        let trips = info.clockSamples.map { RoundTrip(t1: $0.t1, t2: $0.t2, t3: $0.t3, t4: $0.t4) }
        if let videoStart = session.videoStartHostTime, let clock = ClockSync.estimate(trips) {
            // clock.offset = phoneClock - watchClock
            return videoStart - (info.audioStartHostTime + clock.offset)
        }
        // No ping made it through: trust the system clocks (the watch syncs time from the iPhone).
        if let videoWall = session.videoStartWallTime {
            return videoWall.timeIntervalSince(info.audioStartWallTime)
        }
        return nil
    }

    // MARK: - Composition

    /// Watch audio file and the offset to apply (sync + manual correction).
    static func audioSource(for session: RecordingSession) -> MovieComposer.AudioSource? {
        guard session.usesWatch, let sync = session.sync else { return nil }
        // Positive manualOffset = audio plays later.
        if let filled = session.filledAudioFileName {
            // Already on the video's timeline. A manual shift moves the iPhone's parts along with the
            // watch's, which is fine: it's small, and only needed when the sync itself was wrong.
            return .init(url: SessionStore.fileURL(for: session.id, name: filled), offset: -session.manualOffset)
        }
        if let corrected = session.correctedAudioFileName {
            // The corrected file is time-scaled by 1/ratio, so its timeline is target / ratio.
            return .init(url: SessionStore.fileURL(for: session.id, name: corrected),
                         offset: sync.offset / sync.ratio - session.manualOffset)
        }
        guard let name = session.watchAudioFileName else { return nil }
        return .init(url: SessionStore.fileURL(for: session.id, name: name), offset: sync.offset - session.manualOffset)
    }

    func composition(for session: RecordingSession) async throws -> AVMutableComposition {
        try await MovieComposer.makeComposition(
            videoURL: SessionStore.videoURL(for: session.id),
            audio: Self.audioSource(for: session),
            keepPhoneAudio: settings.values.includePhoneAudioTrack
        )
    }

    // MARK: - Export & save

    /// Writes the final clip into the session folder and returns its URL.
    func exportClip(_ id: UUID) async throws -> URL {
        guard !busy.contains(id) else { throw ProcessingError.busy }
        guard let session = store.session(id) else { throw CocoaError(.fileNoSuchFile) }
        busy.insert(id)
        defer { busy.remove(id) }
        return try await withBackgroundTime("Export clip") { try await writeClip(for: session) }
    }

    private func writeClip(for session: RecordingSession) async throws -> URL {
        let composition = try await composition(for: session)
        let url = SessionStore.fileURL(for: session.id, name: Self.clipFileName(for: session))
        try await MovieComposer.export(composition, to: url, creationDate: session.createdAt)
        return url
    }

    func saveToPhotos(_ id: UUID) async throws {
        guard !busy.contains(id) else { throw ProcessingError.busy }
        guard let session = store.session(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }

        try await withBackgroundTime("Save to Photos") {
            let url = try await writeClip(for: session)
            defer { try? FileManager.default.removeItem(at: url) }
            try await PhotoLibrarySaver.saveVideo(at: url, creationDate: session.createdAt)
        }

        store.update(id) {
            $0.status = .saved
            $0.savedAt = Date()
            $0.errorMessage = nil
        }
        if settings.values.deleteSourcesAfterSave { deleteSources(id) }
    }

    private func autoSaveIfNeeded(_ id: UUID) async {
        guard settings.values.autoSaveToPhotos,
              let session = store.session(id),
              session.status == .ready, session.savedAt == nil, !session.autoSaveAttempted else { return }
        // An approximate sync needs a human look first.
        if session.usesWatch, session.sync?.isApproximate ?? true { return }

        store.update(id) { $0.autoSaveAttempted = true }
        let entries = backgroundEntries
        do {
            try await saveToPhotos(id)
        } catch MovieComposer.ComposerError.interrupted {
            logger.info("Auto-save was interrupted by leaving the app, will run again")
            store.update(id) { $0.autoSaveAttempted = false }
            // Without a new departure this isn't about the app state: wait for the next return, don't loop.
            if backgroundEntries != entries { retryIfOnScreen(id) }
        } catch {
            logger.error("Auto-save failed: \(error.localizedDescription, privacy: .public)")
            store.update(id) { $0.errorMessage = error.localizedDescription }
        }
    }

    /// Original video plus a WAV of the watch audio aligned to the video's first frame,
    /// for editing in DaVinci Resolve / Final Cut: put both at 00:00 on the timeline.
    func exportSources(_ id: UUID) async throws -> [URL] {
        guard !busy.contains(id) else { throw ProcessingError.busy }
        guard let session = store.session(id), !session.sourcesDeleted else { throw CocoaError(.fileNoSuchFile) }
        busy.insert(id)
        defer { busy.remove(id) }
        return try await withBackgroundTime("Export sources") { try await writeSources(for: session) }
    }

    private func writeSources(for session: RecordingSession) async throws -> [URL] {
        let id = session.id
        let folder = Self.sourcesExportFolder(for: id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = (Self.clipFileName(for: session) as NSString).deletingPathExtension

        // A hard link is instant and takes no space; the document picker makes the real copy.
        let video = folder.appendingPathComponent("\(baseName)_video.mov")
        let original = SessionStore.videoURL(for: id)
        do {
            try FileManager.default.linkItem(at: original, to: video)
        } catch {
            try FileManager.default.copyItem(at: original, to: video)
        }
        var urls = [video]

        if let source = Self.audioSource(for: session), let duration = session.videoDuration {
            let wav = folder.appendingPathComponent("\(baseName)_watch.wav")
            try await Task.detached(priority: .userInitiated) {
                try AudioFileTools.writeAligned(input: source.url, offset: source.offset, videoDuration: duration, output: wav)
            }.value
            urls.append(wav)
        }
        return urls
    }

    nonisolated static func sourcesExportFolder(for id: UUID) -> URL {
        SessionStore.directory(for: id).appendingPathComponent("Export", isDirectory: true)
    }

    /// The take will never get watch audio: use the iPhone's own sound.
    func useIPhoneAudioOnly(_ id: UUID) {
        store.update(id) {
            $0.usesWatch = false
            $0.status = .ready
        }
        processIfReady(id)
    }

    func setManualOffset(_ seconds: Double, for id: UUID) {
        store.update(id) {
            $0.manualOffset = seconds
            if $0.status == .saved { $0.status = .ready }
        }
    }

    func deleteSources(_ id: UUID) {
        guard let session = store.session(id) else { return }
        let names = ["video.mov", session.watchAudioFileName, session.correctedAudioFileName, session.filledAudioFileName].compactMap { $0 }
        for name in names {
            try? FileManager.default.removeItem(at: SessionStore.fileURL(for: id, name: name))
        }
        store.update(id) { $0.sourcesDeleted = true }
    }

    static func clipFileName(for session: RecordingSession) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "WatchCam_\(formatter.string(from: session.createdAt)).mov"
    }
}

/// A UIKit background task: extra running time after the app leaves the screen.
@MainActor
private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
