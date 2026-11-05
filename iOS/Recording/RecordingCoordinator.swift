import AVFoundation
import Observation
import SwiftUI
import os

/// The conductor: starts and stops the iPhone camera and the watch together,
/// keeps the session records up to date and hands finished takes to the processor.
@MainActor @Observable
final class RecordingCoordinator {
    enum Phase: Equatable {
        case idle
        /// Asked the watch to start its microphone, waiting for the answer.
        case startingWatch
        case recording
        case stopping
    }

    enum WatchState: Equatable {
        case notPaired
        case appNotInstalled
        case unreachable
        case appNotActive
        case ready
        case recording
    }

    struct Prompt: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        /// Offer "record with iPhone only".
        var offersPhoneOnly = false
    }

    let settings: AppSettings
    let store: SessionStore
    let processor: SessionProcessor
    let camera = CameraController()

    private(set) var phase: Phase = .idle
    private(set) var currentSessionID: UUID?
    private(set) var recordingStartedAt: Date?
    private(set) var recordingUsesWatch = false
    /// Last take, for the banner under the record button.
    private(set) var lastSessionID: UUID?
    private(set) var watchStatus: WatchStatus?
    private(set) var lastWatchContact: Date?
    /// What the watch said last while its app was off screen. Arrives every few seconds at best.
    private(set) var backgroundWatchStatus: WatchStatus?
    private(set) var lastBackgroundContact: Date?
    /// Ticks every second so time-based state (watch freshness) re-evaluates.
    private(set) var now = Date()
    private(set) var thermalWarning: String?
    var prompt: Prompt?
    /// Bumped when WatchConnectivity state changes (pairing, reachability).
    private var linkRevision = 0

    @ObservationIgnored private let link = PhoneLink()
    @ObservationIgnored private let logger = Logger(subsystem: "WatchCam", category: "Coordinator")
    @ObservationIgnored private var stoppedSessionIDs: [UUID] = []
    @ObservationIgnored private var scenePhase: ScenePhase = .background
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    init() {
        settings = AppSettings()
        store = SessionStore()
        processor = SessionProcessor(store: store, settings: settings)

        link.onWatchStatus = { [weak self] status in self?.receive(status) }
        link.onStartRequest = { [weak self] id, reply in
            guard let self else { return reply(.failed(.phoneAppNotActive)) }
            self.handleWatchStart(id, reply: reply)
        }
        link.onStopRequest = { [weak self] id in self?.handleWatchStop(id) }
        link.onZoomRequest = { [weak self] zoom in
            // Gentle ramp: crown messages arrive in small steps, the ramp smooths between them.
            self?.camera.setZoom(zoom, animated: true, rate: 4)
        }
        link.onAudioFile = { [weak self] info, url in self?.receiveAudio(info, at: url) }
        link.onRecordingLost = { [weak self] id in self?.watchLostRecording(id) }
        link.onBackgroundWatchStatus = { [weak self] status in
            self?.backgroundWatchStatus = status
            self?.lastBackgroundContact = Date()
        }
        link.onStateChange = { [weak self] in
            self?.linkRevision += 1
            self?.pushContext()
        }
        link.activate()
        camera.onPreviewFrame = { [link] jpeg in link.sendPreviewFrame(jpeg) }
        camera.canSendPreviewFrame = { [link] in link.canSendPreviewFrame }

        recoverInterruptedSessions()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermalWarning() }
        }
        updateThermalWarning()
    }

    private func tick() {
        now = Date()
        // The watch went quiet (wrist down, app closed): stop making preview frames.
        if let lastWatchContact, now.timeIntervalSince(lastWatchContact) > 3 {
            camera.setPreviewWanted(false)
        }
        publishPhoneStatus()
    }

    private func updateThermalWarning() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: thermalWarning = "iPhone нагрелся: снизьте частоту кадров или уберите его с солнца"
        case .critical: thermalWarning = "iPhone перегрет: камера может остановиться"
        default: thermalWarning = nil
        }
    }

    // MARK: - State for the UI

    var watchState: WatchState {
        _ = (now, linkRevision)
        guard link.isPaired else { return .notPaired }
        guard link.isWatchAppInstalled else { return .appNotInstalled }
        if let watchStatus, let lastWatchContact, now.timeIntervalSince(lastWatchContact) < 3.5 {
            if watchStatus.isRecording { return .recording }
            return watchStatus.isAppActive ? .ready : .appNotActive
        }
        return link.isReachable ? .appNotActive : .unreachable
    }

    var watchLevelDB: Float? {
        guard phase == .recording, recordingUsesWatch, watchState == .recording else { return nil }
        return watchStatus?.levelDB
    }

    struct WatchNote: Equatable {
        enum Kind { case fine, unknown, problem }
        var text: String
        var kind: Kind
    }

    /// What to say about the watch's sound while filming, when the live status doesn't cover it.
    var watchRecordingNote: WatchNote? {
        guard phase == .recording, recordingUsesWatch else { return nil }
        let silent = WatchNote(text: "Часы не пишут звук", kind: .problem)
        if watchState == .recording {
            return watchStatus?.isCapturing == false ? silent : nil
        }
        // Its app off screen, the watch can't answer heartbeats, but it sends a short status every few seconds.
        if let status = backgroundWatchStatus, let contact = lastBackgroundContact,
           now.timeIntervalSince(contact) < 15, status.sessionID == currentSessionID {
            return status.isCapturing == false ? silent : WatchNote(text: "Пишут в фоне", kind: .fine)
        }
        // Not a sign of trouble by itself: the watch records on its own and sends the file afterwards.
        return WatchNote(text: "Часы в фоне", kind: .unknown)
    }

    /// The freshest thing the watch said, through either channel.
    private var latestWatchStatus: WatchStatus? {
        if let lastBackgroundContact, lastBackgroundContact > (lastWatchContact ?? .distantPast) {
            return backgroundWatchStatus
        }
        return watchStatus
    }

    var watchTransferProgress: Double? {
        guard let status = latestWatchStatus, status.pendingTransfers > 0 else { return nil }
        return status.transferProgress
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        scenePhase = newPhase
        switch newPhase {
        case .active:
            camera.configure(with: settings.values.capture)
            camera.startRunning()
            // The phone sits on a tripod: the screen must not lock, or the camera stops.
            UIApplication.shared.isIdleTimerDisabled = true
            processor.processPending()
        case .background:
            // iOS stops the camera in the background; finish the file cleanly ourselves.
            if phase == .recording { stop() }
            camera.stopRunning()
            processor.appDidEnterBackground()
            UIApplication.shared.isIdleTimerDisabled = false
        default:
            break
        }
        publishPhoneStatus()
    }

    func settingsChanged() {
        camera.apply(settings.values.capture)
        pushContext()
    }

    // MARK: - Start / stop

    func recordButtonTapped() {
        switch phase {
        case .idle: startFromPhone()
        case .recording: stop()
        case .startingWatch, .stopping: break
        }
    }

    func startFromPhone(phoneOnly: Bool = false) {
        guard phase == .idle, camera.status == .ready else { return }
        let id = UUID()
        if phoneOnly {
            beginVideo(id, usesWatch: false)
            return
        }
        switch watchState {
        case .notPaired:
            prompt = Prompt(title: "Часы не найдены", message: "iPhone не сопряжён с Apple Watch.", offersPhoneOnly: true)
            return
        case .appNotInstalled:
            prompt = Prompt(title: "WatchCam нет на часах",
                            message: "Установите приложение на часы: «Watch» на iPhone → WatchCam → «Установить».",
                            offersPhoneOnly: true)
            return
        case .unreachable:
            prompt = Prompt(title: "Нет связи с часами", message: FailureReason.unreachable.message, offersPhoneOnly: true)
            return
        case .ready, .appNotActive, .recording:
            break
        }

        phase = .startingWatch
        currentSessionID = id
        link.send(.startRecording(sessionID: id, format: settings.values.watchAudioFormat)) { [weak self] reply in
            guard let self, self.phase == .startingWatch, self.currentSessionID == id else { return }
            switch reply {
            case .ok?:
                self.beginVideo(id, usesWatch: true)
            case .failed(let reason)?:
                self.resetToIdle()
                self.prompt = Prompt(title: "Часы не готовы", message: reason.message, offersPhoneOnly: true)
            case nil, .phoneStatus?:
                self.resetToIdle()
                self.prompt = Prompt(title: "Часы не ответили", message: FailureReason.watchAppNotActive.message, offersPhoneOnly: true)
            }
        }
    }

    func stop() {
        guard phase == .recording, let id = currentSessionID else { return }
        phase = .stopping
        camera.stopRecording()
        if recordingUsesWatch { tellWatchToStop(id) }
    }

    private func handleWatchStart(_ id: UUID, reply: @escaping (WCReply) -> Void) {
        guard scenePhase != .background else { return reply(.failed(.phoneAppNotActive)) }
        guard camera.status == .ready, camera.isRunning else { return reply(.failed(.cameraNotReady)) }
        guard phase == .idle else {
            return reply(currentSessionID == id ? .ok : .failed(.phoneBusy))
        }
        prompt = nil
        beginVideo(id, usesWatch: true)
        reply(.ok)
    }

    private func handleWatchStop(_ id: UUID) {
        guard currentSessionID == id, phase == .recording else { return }
        phase = .stopping
        camera.stopRecording()
        markStopped(id)
    }

    private func beginVideo(_ id: UUID, usesWatch: Bool) {
        let capture = settings.values.capture
        store.insert(RecordingSession(
            id: id,
            createdAt: Date(),
            status: .recording,
            usesWatch: usesWatch,
            captureSummary: camera.activeFormatSummary.isEmpty ? capture.summary : camera.activeFormatSummary,
            frameRate: capture.frameRate
        ))
        currentSessionID = id
        lastSessionID = id
        recordingUsesWatch = usesWatch
        recordingStartedAt = Date()
        phase = .recording

        camera.startRecording(
            to: SessionStore.videoURL(for: id),
            onStart: { [weak self] hostTime, isPrecise in
                self?.store.update(id) { session in
                    session.videoStartHostTime = hostTime
                    session.videoStartWallTime = Date().addingTimeInterval(hostTime - HostClock.now())
                    session.videoStartIsPrecise = isPrecise
                }
            },
            onFinish: { [weak self] error in
                self?.videoFinished(id, error: error)
            }
        )
        publishPhoneStatus()
    }

    private func videoFinished(_ id: UUID, error: Error?) {
        let wasStoppedByUser = phase == .stopping
        let usesWatch = recordingUsesWatch
        resetToIdle()
        // Interrupted by a call, backgrounding, a full disk…: make sure the watch stops too.
        if !wasStoppedByUser, usesWatch { tellWatchToStop(id) }

        if let error {
            logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
            store.update(id) {
                $0.status = .failed
                $0.errorMessage = "Видео не записалось: \(error.localizedDescription)"
            }
            return
        }
        Task { await finalizeVideo(id) }
    }

    /// Reads the movie duration and moves the session on to the next status.
    private func finalizeVideo(_ id: UUID) async {
        let url = SessionStore.videoURL(for: id)
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        store.update(id) { session in
            guard duration > 0 else {
                session.status = .failed
                session.errorMessage = "Видеофайл повреждён."
                return
            }
            session.videoFinished = true
            session.videoDuration = duration
            if !session.usesWatch {
                session.status = .ready
            } else {
                session.status = session.hasWatchAudio ? .processing : .waitingForWatch
            }
        }
        processor.processIfReady(id)
    }

    private func resetToIdle() {
        phase = .idle
        currentSessionID = nil
        recordingStartedAt = nil
        recordingUsesWatch = false
        publishPhoneStatus()
    }

    /// Three ways to reach the watch, because a watch with the wrist down may not get live messages:
    /// a direct message, the heartbeat replies (via the stopped list) and the application context.
    private func tellWatchToStop(_ id: UUID) {
        markStopped(id)
        link.send(.stopRecording(sessionID: id)) { _ in }
    }

    private func markStopped(_ id: UUID) {
        stoppedSessionIDs.append(id)
        if stoppedSessionIDs.count > 10 { stoppedSessionIDs.removeFirst(stoppedSessionIDs.count - 10) }
        publishPhoneStatus()
        pushContext()
    }

    // MARK: - Watch data

    private func receive(_ status: WatchStatus) {
        watchStatus = status
        lastWatchContact = Date()
        camera.setPreviewWanted(status.wantsPreview && scenePhase != .background)
    }

    private func receiveAudio(_ info: WatchRecordingInfo, at url: URL) {
        guard store.session(info.sessionID) != nil else {
            // A recording the phone doesn't know (the phone never started): nothing to pair it with.
            logger.warning("Dropping watch audio for unknown session \(info.sessionID, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return
        }
        store.update(info.sessionID) {
            $0.watchInfo = info
            $0.watchAudioFileName = url.lastPathComponent
            if $0.status == .waitingForWatch { $0.status = .processing }
        }
        processor.processIfReady(info.sessionID)
    }

    /// Nothing will ever come from the watch for this take: don't keep waiting for it.
    private func watchLostRecording(_ id: UUID) {
        guard let session = store.session(id), session.usesWatch, !session.hasWatchAudio else { return }
        logger.warning("The watch has no audio for \(id, privacy: .public)")
        if session.status == .recording {
            // Still filming: the status settles when the video finishes.
            store.update(id) { $0.usesWatch = false }
            if currentSessionID == id { recordingUsesWatch = false }
        } else {
            processor.useIPhoneAudioOnly(id)
        }
    }

    private func publishPhoneStatus() {
        link.setPhoneStatus(PhoneStatus(
            isAppActive: scenePhase != .background,
            isCameraReady: camera.status == .ready && camera.isRunning,
            isRecording: phase == .recording || phase == .stopping,
            sessionID: currentSessionID,
            stoppedSessionIDs: stoppedSessionIDs,
            zoom: Double(camera.displayZoom),
            minZoom: Double(camera.minDisplayZoom),
            maxZoom: Double(camera.maxDisplayZoom),
            zoomSteps: camera.zoomSteps.map(Double.init)
        ))
    }

    private func pushContext() {
        link.updateContext(PhoneContext(audioFormat: settings.values.watchAudioFormat, stoppedSessionIDs: stoppedSessionIDs))
    }

    /// After a crash or a kill during recording. AVCaptureMovieFileOutput writes movie fragments
    /// every 10 s, so the file is usually readable up to the last fragment.
    private func recoverInterruptedSessions() {
        for session in store.sessions where session.status == .recording {
            Task { await finalizeVideo(session.id) }
        }
    }
}
