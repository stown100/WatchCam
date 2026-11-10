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
    /// The last frame is recent. Checked on a timer: with no new frames the view itself wouldn't
    /// notice, and an old frame would stay on screen as if it were live.
    private(set) var isPreviewFresh = false
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
            guard isAppActive != oldValue else { return }
            Journal.log("app \(isAppActive ? "on screen" : "off screen"), locked \(Journal.isLocked.map(String.init) ?? "unknown")")
            guard isAppActive else { return }
            lastHeartbeat = 0
            Journal.prepareLockProbe()
            requestMicrophonePermissionIfNeeded()
            resendPendingRecordings()
            // Only possible on screen: pick up what couldn't be done in the background.
            if phase != .idle {
                keepAlive.start()
                recorder.restartIfStalled()
            }
        }
    }

    /// While recording: the microphone is really delivering sound.
    private(set) var isCapturing = true

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let keepAlive = RecordingKeepAlive()
    @ObservationIgnored private let link = WatchLink()
    /// What to send the current recording in.
    @ObservationIgnored private var requestedFormat = WatchAudioFormat.aac
    @ObservationIgnored private var compressing: Set<UUID> = []
    /// Takes with nothing to send, for the phone to stop waiting.
    @ObservationIgnored private var lostRecordings: [UUID] = []
    @ObservationIgnored private var lastCheckpoint: Double = 0
    @ObservationIgnored private var lastDiaryLine: Double = 0
    @ObservationIgnored private var lastRestartAttempt: Double = 0
    /// Since when the preview page has been waiting for frames from a ready iPhone.
    @ObservationIgnored private var previewWaitingSince: Date?
    @ObservationIgnored private var previewWaitLogged = false
    /// When each transfer was queued and how big the file was, to write down the speed.
    @ObservationIgnored private var transferStarts: [UUID: (date: Date, bytes: Int, previewOpen: Bool)] = [:]
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

        Journal.log("app launched")
        recoverInterruptedRecordings()
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

    /// A focus point or lock set on the phone's screen, while the camera is there to show it.
    var phoneFocus: PhoneFocus? {
        switch phoneState {
        case .ready, .recording: phoneStatus?.focus
        default: nil
        }
    }

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

    /// Puts the phone's focus back to automatic.
    func resetPhoneFocus() {
        Journal.log("asking the iPhone to reset its focus (was \(phoneStatus?.focus?.rawValue ?? "automatic"))")
        link.send(.resetFocus, timeout: 2) { [weak self] reply, _ in
            guard let self else { return }
            if reply == nil { Journal.log("focus reset didn't reach the iPhone") }
            // Ask for the phone's status now: the badge goes away only once the phone confirms.
            self.lastHeartbeat = 0
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
        finishRecording(because: "stopped on the watch")
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
        finishRecording(because: "stop message from the phone")
    }

    private func apply(_ context: PhoneContext) {
        if audioFormat != context.audioFormat {
            audioFormat = context.audioFormat
            UserDefaults.standard.set(audioFormat.rawValue, forKey: Self.audioFormatKey)
        }
        if let sessionID, context.stoppedSessionIDs.contains(sessionID) {
            finishRecording(because: "stop in the phone's context")
        }
    }

    // MARK: - Recording

    private func beginRecording(_ id: UUID, format: WatchAudioFormat) throws {
        try recorder.start(url: PendingRecordings.audioURL(for: id))
        keepAlive.start()
        requestedFormat = format
        sessionID = id
        recordingStartedAt = Date()
        clockSamples = []
        phoneMismatchCount = 0
        levelDB = -160
        isCapturing = true
        lastCheckpoint = 0
        lastDiaryLine = 0
        // A quick burst of pings right after the start gives a good clock estimate early.
        burstUntil = HostClock.now() + 1.5
        Journal.log("recording \(id) started, locked \(Journal.isLocked.map(String.init) ?? "unknown")")
    }

    private func abortRecording() {
        _ = recorder.stop()
        if let sessionID { PendingRecordings.remove(sessionID) }
        sessionID = nil
        recordingStartedAt = nil
        phase = .idle
        Journal.log("recording aborted")
        stopKeepAliveIfDone()
    }

    /// Stops the microphone, saves metadata and queues the file for transfer.
    private func finishRecording(because reason: String) {
        guard let id = sessionID else { return }
        Journal.log("stopping: \(reason)")
        let result = recorder.stop()
        let format = requestedFormat
        let info = result.map { makeInfo(id, from: $0) }
        sessionID = nil
        recordingStartedAt = nil
        phase = .idle
        levelDB = -160
        isCapturing = true
        WKInterfaceDevice.current().play(.stop)

        guard let info else {
            // The microphone never gave a single sample.
            Journal.log("recording \(id) ended with no sound at all")
            PendingRecordings.remove(id)
            link.sendQueued(.recordingLost(sessionID: id))
            message = "Запись со звуком не сохранилась."
            stopKeepAliveIfDone()
            return
        }
        Journal.log(String(format: "recording %@ finished: %.1f s, %.1f s of silence", id.uuidString, info.duration, info.silenceInserted))
        // Safe as it is from here on, whatever happens during the compression.
        PendingRecordings.save(info)
        guard format == .aac else {
            send(info)
            return
        }
        compressing.insert(id)
        Task {
            let compressed = await Task.detached(priority: .userInitiated) { PendingRecordings.compress(info) }.value
            compressing.remove(id)
            Journal.log("compressed: \(compressed != nil)")
            send(compressed ?? info)
        }
    }

    private func send(_ info: WatchRecordingInfo) {
        let url = PendingRecordings.audioURL(for: info.sessionID)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let previewOpen = isAppActive && isPreviewVisible
        transferStarts[info.sessionID] = (Date(), bytes, previewOpen)
        link.transfer(info, from: url)
        updateTransfers()
        Journal.log("transfer of \(info.sessionID) queued: \(info.format.rawValue), \(bytes / 1024) KB, locked \(Journal.isLocked.map(String.init) ?? "unknown"), preview page \(previewOpen ? "open" : "closed")")
        publishStatusIfOffScreen()
        stopKeepAliveIfDone()
    }

    /// From here the system carries the file over: the app is free to be suspended.
    private func stopKeepAliveIfDone() {
        if sessionID == nil, compressing.isEmpty { keepAlive.stop() }
    }

    private func makeInfo(_ id: UUID, from result: AudioRecorder.Result) -> WatchRecordingInfo {
        WatchRecordingInfo(
            sessionID: id,
            format: .pcm,
            fileExtension: result.url.pathExtension,
            sampleRate: result.sampleRate,
            hardwareSampleRate: result.hardwareSampleRate,
            audioStartHostTime: result.startHostTime,
            audioStartWallTime: result.startWallTime,
            duration: result.duration,
            silenceInserted: result.silenceInserted,
            clockSamples: Array(clockSamples.sorted { $0.delay < $1.delay }.prefix(40)),
            gaps: result.gaps.isEmpty ? nil : result.gaps
        )
    }

    /// The app died during a recording last time: what it saved goes to the phone like any other file.
    private func recoverInterruptedRecordings() {
        let recovery = PendingRecordings.recoverInterrupted()
        lostRecordings = recovery.lost
        for info in recovery.recovered {
            Journal.log(String(format: "recovered %@: %.1f s", info.sessionID.uuidString, info.duration))
        }
        for id in recovery.lost { Journal.log("nothing usable left of \(id)") }
        if !recovery.recovered.isEmpty {
            message = "Запись оборвалась, но сохранённая часть отправляется на iPhone."
        }
    }

    // MARK: - Watching over a recording

    private static let stalledMessage = "Микрофон не пишет. iPhone подставит свой звук за это время."

    private func watchOverRecording() {
        let now = HostClock.now()

        // Everything needed to use the file if the app dies. The first one comes right after the first sample.
        if lastCheckpoint == 0 || now - lastCheckpoint >= 5, let id = sessionID, let progress = recorder.progress {
            PendingRecordings.saveCheckpoint(makeInfo(id, from: progress))
            lastCheckpoint = now
        }

        let quiet = recorder.secondsSinceLastBuffer ?? 0
        let capturing = quiet < AudioRecorder.stallTime
        if capturing != isCapturing {
            isCapturing = capturing
            Journal.log(capturing ? "microphone delivering again" : "microphone stopped delivering")
            publishStatusIfOffScreen()
            if !capturing {
                message = Self.stalledMessage
            } else if message == Self.stalledMessage {
                message = nil
            }
        }
        if !capturing, isAppActive, now - lastRestartAttempt >= 2 {
            lastRestartAttempt = now
            recorder.restartIfStalled()
        }

        // A hole between these lines means the app wasn't running.
        if now - lastDiaryLine >= 5 {
            lastDiaryLine = now
            publishStatusIfOffScreen()
            let state = WKApplication.shared().applicationState.rawValue
            let locked = Journal.isLocked.map(String.init) ?? "unknown"
            let seconds = recorder.progress?.duration ?? 0
            Journal.log(String(format: "alive: state %d, locked %@, recorded %.1f s, quiet %.1f s, engine %@, keep-alive %@, reachable %@, level %.0f dB",
                               state, locked, seconds, quiet, recorder.isEngineRunning ? "on" : "off",
                               keepAlive.isRunning ? "on" : "off", isPhoneReachable ? "yes" : "no", levelDB))
        }
    }

    // MARK: - Preview

    private func updatePreviewFreshness() {
        let fresh = previewReceivedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        if fresh != isPreviewFresh { isPreviewFresh = fresh }

        // Written down when the page waits in vain, so a broken preview leaves a trace.
        let waiting = isAppActive && isPreviewVisible && !fresh && (phoneState == .ready || phoneState == .recording)
        if !waiting {
            if previewWaitLogged, fresh { Journal.log("preview frames arriving") }
            previewWaitingSince = nil
            previewWaitLogged = false
        } else if let since = previewWaitingSince {
            if !previewWaitLogged, Date().timeIntervalSince(since) > 5 {
                previewWaitLogged = true
                Journal.log("preview page open, no frames from the iPhone for 5 s (iPhone \(phoneState), reachable \(isPhoneReachable))")
            }
        } else {
            previewWaitingSince = Date()
        }
    }

    // MARK: - Heartbeat (status + NTP ping)

    private func tick() {
        tickCount += 1
        if tickCount % 5 == 0 { updateTransfers() }
        updatePreviewFreshness()
        if phase != .idle { watchOverRecording() }

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
        let status = currentStatus()
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
                if phone.stoppedSessionIDs.contains(recordingSession) {
                    self.finishRecording(because: "stop in the phone's status")
                } else if self.phoneMismatchCount >= 3 {
                    self.finishRecording(because: "the phone isn't filming this take")
                }
            }
        }
    }

    private func currentStatus() -> WatchStatus {
        WatchStatus(
            isAppActive: isAppActive,
            isRecording: phase != .idle,
            sessionID: sessionID,
            recordingStartedAt: recordingStartedAt,
            levelDB: phase == .idle ? nil : levelDB,
            pendingTransfers: pendingTransfers,
            transferProgress: transferProgress,
            wantsPreview: isAppActive && isPreviewVisible,
            isCapturing: phase == .idle ? nil : isCapturing
        )
    }

    /// Off screen, heartbeats can't reach the phone: tell it how things are through the slower channel.
    private func publishStatusIfOffScreen() {
        guard !isAppActive else { return }
        link.publishStatus(currentStatus())
    }

    // MARK: - Transfers

    private func updateTransfers() {
        let transfers = link.outstandingTransfers
        pendingTransfers = transfers.count
        transferProgress = transfers.isEmpty ? nil : transfers.map(\.progress.fractionCompleted).min()
    }

    private func transferFinished(_ id: UUID, error: Error?) {
        var speed = ""
        if let start = transferStarts.removeValue(forKey: id) {
            let seconds = Date().timeIntervalSince(start.date)
            speed = String(format: " after %.0f s (%.0f KB/s from queuing; preview page was %@ at the start)",
                           seconds, Double(start.bytes) / 1024 / max(seconds, 0.1), start.previewOpen ? "open" : "closed")
        }
        Journal.log("transfer of \(id) finished\(speed), error \(error?.localizedDescription ?? "none")")
        defer { publishStatusIfOffScreen() }
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
        for info in PendingRecordings.all()
        where !queued.contains(info.sessionID) && info.sessionID != sessionID && !compressing.contains(info.sessionID) {
            link.transfer(info, from: PendingRecordings.audioURL(for: info.sessionID))
        }
        for id in lostRecordings { link.sendQueued(.recordingLost(sessionID: id)) }
        lostRecordings = []
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
