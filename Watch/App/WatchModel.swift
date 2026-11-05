import AVFoundation
import Foundation
import Observation
import WatchKit

/// State and logic of the watch app.
@MainActor @Observable
final class WatchModel {
    enum Phase: Equatable {
        case idle
        /// Microphone is running, waiting for the iPhone to confirm the camera started.
        case starting
        case recording
    }

    enum PhoneState: Equatable {
        case unreachable
        case connecting
        case appNotActive
        case cameraNotReady
        case ready
        case recording
    }

    private(set) var phase: Phase = .idle
    private(set) var recordingStartedAt: Date?
    private(set) var levelDB: Float = -160
    private(set) var isPhoneReachable = false
    private(set) var phoneStatus: PhoneStatus?
    private(set) var lastPhoneContact: Date?
    private(set) var pendingTransfers = 0
    private(set) var transferProgress: Double?
    private(set) var message: String?
    private(set) var audioFormat: WatchAudioFormat
    /// Latest small frame from the iPhone camera.
    private(set) var previewImage: UIImage?
    private(set) var previewReceivedAt: Date?
    /// The preview page is on screen: ask the phone for frames.
    var isPreviewVisible = false {
        didSet {
            // Tell the phone right away instead of waiting for the next heartbeat.
            if isPreviewVisible != oldValue { lastHeartbeat = 0 }
        }
    }

    /// Updated from the scene phase. Recording can only *start* while the app is active.
    var isAppActive = false {
        didSet {
            guard isAppActive, !oldValue else { return }
            lastHeartbeat = 0
            requestMicrophonePermissionIfNeeded()
            resendPendingRecordings()
        }
    }

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let link = WatchLink()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var clockSamples: [ClockSample] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var heartbeatInFlight = false
    @ObservationIgnored private var lastHeartbeat: Double = 0
    @ObservationIgnored private var burstUntil: Double = 0
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var phoneMismatchCount = 0
    @ObservationIgnored private var pendingZoom: Double?
    @ObservationIgnored private var zoomInFlight = false
    @ObservationIgnored private var lastCrownInteraction = Date.distantPast
    @ObservationIgnored private var crownTargetZoom: Double?
    @ObservationIgnored private var crown = MagneticCrown()

    private static let audioFormatKey = "audioFormat"

    init() {
        audioFormat = WatchAudioFormat(rawValue: UserDefaults.standard.string(forKey: Self.audioFormatKey) ?? "") ?? .aac

        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.levelDB = level }
        }
        link.onStartCommand = { [weak self] sessionID, format, reply in
            guard let self else { return reply(.failed(.watchAppNotActive)) }
            self.handleRemoteStart(sessionID, format: format, reply: reply)
        }
        link.onStopCommand = { [weak self] sessionID in
            self?.handleRemoteStop(sessionID)
        }
        link.onContext = { [weak self] context in
            self?.apply(context)
        }
        link.onActivated = { [weak self] in
            self?.resendPendingRecordings()
        }
        link.onReachabilityChange = { [weak self] reachable in
            self?.isPhoneReachable = reachable
        }
        link.onTransferFinished = { [weak self] sessionID, error in
            self?.transferFinished(sessionID, error: error)
        }
        link.onPreviewFrame = { [weak self] jpeg in
            guard let self, self.isPreviewVisible, let image = UIImage(data: jpeg) else { return }
            self.previewImage = image
            self.previewReceivedAt = Date()
        }
        link.activate()

        PendingRecordings.removeOrphans(except: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var phoneState: PhoneState {
        guard isPhoneReachable else { return .unreachable }
        guard let phoneStatus, let lastPhoneContact, Date().timeIntervalSince(lastPhoneContact) < 5 else {
            return .connecting
        }
        if phoneStatus.isRecording { return .recording }
        if !phoneStatus.isAppActive { return .appNotActive }
        if !phoneStatus.isCameraReady { return .cameraNotReady }
        return .ready
    }

    /// Camera zoom reported by the phone, with its limits.
    var phoneZoom: Double { phoneStatus?.zoom ?? 1 }
    var zoomRange: ClosedRange<Double> {
        guard let phoneStatus, phoneStatus.maxZoom > phoneStatus.minZoom else { return 0.5...10 }
        return phoneStatus.minZoom...phoneStatus.maxZoom
    }
    var zoomDial: ZoomDial { ZoomDial(range: zoomRange, steps: phoneStatus?.zoomSteps ?? []) }

    /// While the user turns the crown, the local value wins over what the phone reports.
    /// Long enough to outlast the phone's status, which can lag by about two seconds.
    var isCrownActive: Bool { Date().timeIntervalSince(lastCrownInteraction) < 2.5 }

    /// Moves the crown to the phone's zoom, for when the zoom changed over there.
    func syncCrownToPhone(dialChanged: Bool = false) {
        guard !isCrownActive else { return }
        // The phone simply arrived where the crown sent it: stay put, or the step's grip would change.
        if !dialChanged, abs(phoneZoom - (crownTargetZoom ?? .infinity)) < 0.02 { return }
        let dial = zoomDial
        crown.move(to: dial.crownPosition(forZoom: phoneZoom))
        crownTargetZoom = dial.zoom(atCrown: crown.position)
    }

    // MARK: - User actions

    /// Digital Crown moved. Sends at most one zoom message at a time, always the latest value.
    func crownMoved(to raw: Double) {
        lastCrownInteraction = Date()
        let dial = zoomDial
        let zoom = crown.turn(to: raw, at: HostClock.now(), on: dial)
        // The same zoom comes again and again while turning across a step.
        guard abs(zoom - (crownTargetZoom ?? .infinity)) > 0.005 else { return }
        crownTargetZoom = zoom
        // Feel the step, but never while recording: the microphone would hear the vibration.
        if phase == .idle, dial.isStep(zoom) { WKInterfaceDevice.current().play(.click) }
        pendingZoom = zoom
        sendPendingZoom()
    }

    private func sendPendingZoom() {
        guard !zoomInFlight, let zoom = pendingZoom else { return }
        pendingZoom = nil
        zoomInFlight = true
        link.send(.setZoom(zoom), timeout: 2) { [weak self] _, _ in
            self?.zoomInFlight = false
            self?.sendPendingZoom()
        }
    }

    func toggleRecording() {
        switch phase {
        case .idle: startFromWatch()
        case .starting, .recording: stopFromWatch()
        }
    }

    func dismissMessage() {
        message = nil
    }

    private func startFromWatch() {
        message = nil
        Task { @MainActor in
            guard await ensureMicrophonePermission() else {
                show(FailureReason.microphoneDenied)
                return
            }
            let id = UUID()
            do {
                try beginRecording(id, format: audioFormat)
            } catch {
                show(.audioFailed)
                return
            }
            phase = .starting

            link.send(.requestStart(sessionID: id)) { reply, _ in
                guard self.sessionID == id, self.phase == .starting else { return }
                switch reply {
                case .ok?:
                    self.phase = .recording
                    WKInterfaceDevice.current().play(.start)
                case .failed(let reason)?:
                    self.abortRecording()
                    self.show(reason)
                default:
                    self.abortRecording()
                    self.show(.phoneAppNotActive)
                }
            }
        }
    }

    private func stopFromWatch() {
        guard let id = sessionID else { return }
        finishRecording()
        link.send(.requestStop(sessionID: id)) { [weak self] reply, _ in
            // If the live message didn't get through, queue it: it arrives when the phone wakes up.
            if reply == nil { self?.link.sendQueued(.requestStop(sessionID: id)) }
        }
    }

    // MARK: - Commands from the phone

    private func handleRemoteStart(_ id: UUID, format: WatchAudioFormat, reply: @escaping (WCReply) -> Void) {
        // watchOS only lets an app start the microphone while it is on screen.
        guard WKApplication.shared().applicationState == .active else {
            return reply(.failed(.watchAppNotActive))
        }
        guard phase == .idle else {
            return reply(sessionID == id ? .ok : .failed(.watchBusy))
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return reply(.failed(.microphoneDenied))
        }
        do {
            try beginRecording(id, format: format)
            phase = .recording
            message = nil
            WKInterfaceDevice.current().play(.start)
            reply(.ok)
        } catch {
            reply(.failed(.audioFailed))
        }
    }

    private func handleRemoteStop(_ id: UUID) {
        guard sessionID == id else { return }
        finishRecording()
    }

    private func apply(_ context: PhoneContext) {
        if audioFormat != context.audioFormat {
            audioFormat = context.audioFormat
            UserDefaults.standard.set(audioFormat.rawValue, forKey: Self.audioFormatKey)
        }
        if let sessionID, context.stoppedSessionIDs.contains(sessionID) {
            finishRecording()
        }
    }

    // MARK: - Recording

    private func beginRecording(_ id: UUID, format: WatchAudioFormat) throws {
        try recorder.start(url: PendingRecordings.audioURL(for: id), format: format)
        sessionID = id
        recordingStartedAt = Date()
        clockSamples = []
        phoneMismatchCount = 0
        levelDB = -160
        // A quick burst of pings right after the start gives a good clock estimate early.
        burstUntil = HostClock.now() + 1.5
    }

    private func abortRecording() {
        _ = recorder.stop()
        if let sessionID { PendingRecordings.remove(sessionID) }
        sessionID = nil
        recordingStartedAt = nil
        phase = .idle
    }

    /// Stops the microphone, saves metadata and queues the file for transfer.
    private func finishRecording() {
        guard let id = sessionID else { return }
        let result = recorder.stop()
        sessionID = nil
        recordingStartedAt = nil
        phase = .idle
        levelDB = -160
        WKInterfaceDevice.current().play(.stop)

        guard let result else {
            PendingRecordings.remove(id)
            message = "Запись со звуком не сохранилась."
            return
        }
        let samples = clockSamples.sorted { $0.delay < $1.delay }.prefix(40)
        let info = WatchRecordingInfo(
            sessionID: id,
            format: result.format,
            fileExtension: result.url.pathExtension,
            sampleRate: result.sampleRate,
            hardwareSampleRate: result.hardwareSampleRate,
            audioStartHostTime: result.startHostTime,
            audioStartWallTime: result.startWallTime,
            duration: result.duration,
            silenceInserted: result.silenceInserted,
            clockSamples: Array(samples)
        )
        PendingRecordings.save(info)
        link.transfer(info, from: result.url)
        updateTransfers()
    }

    // MARK: - Heartbeat (status + NTP ping)

    private func tick() {
        tickCount += 1
        if tickCount % 5 == 0 { updateTransfers() }

        let now = HostClock.now()
        let interval: Double
        switch (phase, isAppActive) {
        case (.idle, false):
            return
        case (.idle, true):
            interval = 1
        case (_, true):
            interval = now < burstUntil ? 0.1 : 0.25
        case (_, false):
            // Wrist down: fewer messages to save battery, still enough to notice a stop from the phone.
            interval = now < burstUntil ? 0.1 : 1
        }
        let stuck = heartbeatInFlight && now - lastHeartbeat > 3
        guard !heartbeatInFlight || stuck, now - lastHeartbeat >= interval else { return }
        sendHeartbeat()
    }

    private func sendHeartbeat() {
        let t1 = HostClock.now()
        lastHeartbeat = t1
        heartbeatInFlight = true
        let status = WatchStatus(
            isAppActive: isAppActive,
            isRecording: phase != .idle,
            sessionID: sessionID,
            recordingStartedAt: recordingStartedAt,
            levelDB: phase == .idle ? nil : levelDB,
            pendingTransfers: pendingTransfers,
            transferProgress: transferProgress,
            wantsPreview: isAppActive && isPreviewVisible
        )
        let recordingSession = sessionID
        link.send(.heartbeat(status, sentAt: t1), timeout: 3) { [weak self] reply, t4 in
            guard let self else { return }
            self.heartbeatInFlight = false
            guard case let .phoneStatus(phone, t2, t3)? = reply else { return }
            self.phoneStatus = phone
            self.lastPhoneContact = Date()

            if let recordingSession, recordingSession == self.sessionID {
                self.clockSamples.append(ClockSample(t1: t1, t2: t2, t3: t3, t4: t4))
                if self.clockSamples.count > 80 {
                    self.clockSamples.sort { $0.delay < $1.delay }
                    self.clockSamples.removeLast(self.clockSamples.count - 40)
                }
                // The phone isn't filming this take any more (e.g. its app was killed and restarted).
                let phoneLostTake = self.phase == .recording && !phone.isRecording && phone.sessionID != recordingSession
                self.phoneMismatchCount = phoneLostTake ? self.phoneMismatchCount + 1 : 0
                // Stop requested on the phone while our live channel was down.
                if phone.stoppedSessionIDs.contains(recordingSession) || self.phoneMismatchCount >= 3 {
                    self.finishRecording()
                }
            }
        }
    }

    // MARK: - Transfers

    private func updateTransfers() {
        let transfers = link.outstandingTransfers
        pendingTransfers = transfers.count
        transferProgress = transfers.isEmpty ? nil : transfers.map(\.progress.fractionCompleted).min()
    }

    private func transferFinished(_ id: UUID, error: Error?) {
        if error == nil {
            PendingRecordings.remove(id)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.resendPendingRecordings()
            }
        }
        updateTransfers()
    }

    /// Re-queues recordings whose transfer was lost (for example, the watch rebooted).
    private func resendPendingRecordings() {
        let queued = Set(link.outstandingTransfers.compactMap {
            WCCoding.decode(WatchRecordingInfo.self, from: $0.file.metadata)?.sessionID
        })
        for info in PendingRecordings.all() where !queued.contains(info.sessionID) && info.sessionID != sessionID {
            link.transfer(info, from: PendingRecordings.audioURL(for: info.sessionID))
        }
        updateTransfers()
    }

    // MARK: - Helpers

    private func show(_ reason: FailureReason) {
        message = reason.message
        WKInterfaceDevice.current().play(.failure)
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func requestMicrophonePermissionIfNeeded() {
        guard AVAudioApplication.shared.recordPermission == .undetermined else { return }
        Task { _ = await AVAudioApplication.requestRecordPermission() }
    }
}
