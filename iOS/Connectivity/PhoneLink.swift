import Foundation
import WatchConnectivity
import os

/// iPhone side of WatchConnectivity.
///
/// Delegate callbacks arrive on a background queue. Heartbeats are answered right there
/// from a lock-protected snapshot, so the NTP timestamps aren't skewed by main-thread latency.
final class PhoneLink: NSObject, WCSessionDelegate {
    var onWatchStatus: (@MainActor (WatchStatus) -> Void)?
    /// The watch asks to start. The reply must be called exactly once.
    var onStartRequest: (@MainActor (UUID, @escaping (WCReply) -> Void) -> Void)?
    var onStopRequest: (@MainActor (UUID) -> Void)?
    var onZoomRequest: (@MainActor (Double) -> Void)?
    var onFocusResetRequest: (@MainActor () -> Void)?
    /// A watch recording arrived and was moved into the session folder.
    var onAudioFile: (@MainActor (WatchRecordingInfo, URL) -> Void)?
    /// The watch has nothing to send for this take.
    var onRecordingLost: (@MainActor (UUID) -> Void)?
    /// Status the watch sends while its app is off screen, when heartbeats can't get through.
    var onBackgroundWatchStatus: (@MainActor (WatchStatus) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    private let session = WCSession.default
    private let logger = Logger(subsystem: "WatchCam", category: "PhoneLink")
    private let lock = NSLock()
    private var phoneStatus = PhoneStatus(isAppActive: false, isCameraReady: false, isRecording: false,
                                          sessionID: nil, stoppedSessionIDs: [], zoom: 1, minZoom: 1, maxZoom: 1, zoomSteps: [])
    /// When the preview frame now on its way was sent; `nil` if the link is free.
    private var previewSentAt: Double?
    private var previewStats = PreviewStats()
    /// Host time of the last heartbeat from the watch.
    private var lastHeartbeatAt: Double = -.infinity
    private var lastPreviewDelivered: Double = -.infinity
    private var lastPreviewError: String?

    /// Preview link quality, logged every few seconds to tune frame size and rate on real devices.
    private struct PreviewStats {
        var startedAt = HostClock.now()
        var delivered = 0
        var failed = 0
        var bytes = 0
        var roundTrip = 0.0
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// For when the app comes back after a long time in the background.
    func activateIfNeeded() {
        guard WCSession.isSupported(), session.activationState != .activated else { return }
        Journal.log("watch link not active (\(session.activationState.rawValue)): activating again")
        activate()
    }

    var isActivated: Bool { session.activationState == .activated }
    var isPaired: Bool { isActivated && session.isPaired }
    var isWatchAppInstalled: Bool { isActivated && session.isWatchAppInstalled }
    var isReachable: Bool { isActivated && session.isReachable }

    /// Whether a live message has a chance. A heartbeat in the last two seconds proves the watch app
    /// is on screen, even if `isReachable` hasn't caught up: it can lag after a long time in the background.
    var canReachWatch: Bool {
        guard isActivated else { return false }
        lock.lock()
        let heartbeat = lastHeartbeatAt
        lock.unlock()
        return session.isReachable || HostClock.now() - heartbeat < 2
    }

    /// When a preview frame last reached the watch (host time), and the last error, if any.
    var previewDelivery: (lastDelivered: Double, lastError: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastPreviewDelivered, lastPreviewError)
    }

    /// Snapshot used to answer heartbeats. Safe to call from any thread.
    func setPhoneStatus(_ status: PhoneStatus) {
        lock.lock()
        phoneStatus = status
        lock.unlock()
    }

    /// Sends a live message. `reply` runs on main, with `nil` on error or timeout.
    func send(_ message: WCMessage, timeout: TimeInterval = 4, reply: @escaping @MainActor (WCReply?) -> Void) {
        let once = OnceGuard<WCReply?> { value in
            DispatchQueue.main.async { reply(value) }
        }
        guard canReachWatch else {
            once.fire(nil)
            return
        }
        session.sendMessageData(WCCoding.encode(message), replyHandler: { data in
            once.fire(WCCoding.decode(WCReply.self, from: data))
        }, errorHandler: { [logger] error in
            logger.error("sendMessage failed: \(error.localizedDescription, privacy: .public)")
            once.fire(nil)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.fire(nil) }
    }

    /// Whether a preview frame can go out right now. Only one frame travels at a time, so a slow
    /// Bluetooth link never builds up a backlog and the watch always gets the freshest frame possible.
    var canSendPreviewFrame: Bool {
        lock.lock()
        let sentAt = previewSentAt
        lock.unlock()
        // A reply can get lost: don't let that freeze the preview.
        if let sentAt, HostClock.now() - sentAt < 2 { return false }
        return canReachWatch
    }

    /// Sends a preview frame as raw JPEG bytes. Check `canSendPreviewFrame` first.
    func sendPreviewFrame(_ jpeg: Data) {
        let sentAt = HostClock.now()
        lock.lock()
        previewSentAt = sentAt
        lock.unlock()
        session.sendMessageData(jpeg, replyHandler: { [weak self] _ in
            self?.previewFrameFinished(sentAt: sentAt, size: jpeg.count, error: nil)
        }, errorHandler: { [weak self] error in
            self?.previewFrameFinished(sentAt: sentAt, size: jpeg.count, error: error)
        })
    }

    private func previewFrameFinished(sentAt: Double, size: Int, error: Error?) {
        let now = HostClock.now()
        lock.lock()
        // A late answer to an abandoned frame must not free the slot of a newer one.
        if previewSentAt == sentAt { previewSentAt = nil }
        // Preview was off for a while: start counting afresh.
        if now - previewStats.startedAt > 10 { previewStats = PreviewStats() }
        if let error {
            previewStats.failed += 1
            let nsError = error as NSError
            lastPreviewError = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        } else {
            previewStats.delivered += 1
            previewStats.bytes += size
            previewStats.roundTrip += now - sentAt
            lastPreviewDelivered = now
            lastPreviewError = nil
        }
        var report: PreviewStats?
        if now - previewStats.startedAt >= 5 {
            report = previewStats
            previewStats = PreviewStats()
        }
        lock.unlock()

        guard let report, report.delivered > 0 else { return }
        let count = Double(report.delivered)
        let elapsed = now - report.startedAt
        logger.info("Watch preview: \(count / elapsed, format: .fixed(precision: 1)) fps, \(Double(report.bytes) / count / 1024, format: .fixed(precision: 1)) KB/frame, round trip \(report.roundTrip / count * 1000, format: .fixed(precision: 0)) ms, failed \(report.failed)")
    }

    /// Queued delivery (survives the watch app being suspended).
    func sendQueued(_ message: WCMessage) {
        guard isActivated, session.isPaired else { return }
        session.transferUserInfo(WCCoding.dictionary(message))
    }

    func updateContext(_ context: PhoneContext) {
        guard isActivated, session.isPaired else { return }
        do {
            try session.updateApplicationContext(WCCoding.dictionary(context))
        } catch {
            logger.error("updateApplicationContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Journal.log("watch link activated: state \(activationState.rawValue), paired \(session.isPaired), app installed \(session.isWatchAppInstalled), reachable \(session.isReachable), error \(error?.localizedDescription ?? "none")")
        notifyStateChange()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        Journal.log("watch link inactive")
        notifyStateChange()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another watch: reactivate for the new one.
        Journal.log("watch link deactivated: activating again")
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Journal.log("watch reachable: \(session.isReachable)")
        notifyStateChange()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Journal.log("watch state changed: paired \(session.isPaired), app installed \(session.isWatchAppInstalled)")
        notifyStateChange()
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let receivedAt = HostClock.now()
        let respond: (WCReply) -> Void = { replyHandler(WCCoding.encode($0)) }
        guard let message = WCCoding.decode(WCMessage.self, from: messageData) else {
            respond(.ok)
            return
        }

        switch message {
        case let .heartbeat(status, _):
            lock.lock()
            let snapshot = phoneStatus
            lastHeartbeatAt = receivedAt
            lock.unlock()
            respond(.phoneStatus(snapshot, receivedAt: receivedAt, sentAt: HostClock.now()))
            DispatchQueue.main.async { self.onWatchStatus?(status) }

        case let .requestStart(sessionID):
            DispatchQueue.main.async {
                guard let handler = self.onStartRequest else { return respond(.failed(.phoneAppNotActive)) }
                handler(sessionID, respond)
            }

        case let .requestStop(sessionID):
            respond(.ok)
            DispatchQueue.main.async { self.onStopRequest?(sessionID) }

        case let .setZoom(zoom):
            respond(.ok)
            DispatchQueue.main.async { self.onZoomRequest?(zoom) }

        case .resetFocus:
            respond(.ok)
            DispatchQueue.main.async { self.onFocusResetRequest?() }

        case let .recordingLost(sessionID):
            respond(.ok)
            DispatchQueue.main.async { self.onRecordingLost?(sessionID) }

        case .startRecording, .stopRecording:
            respond(.ok)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let message = WCCoding.decode(WCMessage.self, from: userInfo) else { return }
        switch message {
        case let .requestStop(sessionID):
            DispatchQueue.main.async { self.onStopRequest?(sessionID) }
        case let .recordingLost(sessionID):
            DispatchQueue.main.async { self.onRecordingLost?(sessionID) }
        default:
            break
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let status = WCCoding.decode(WatchStatus.self, from: applicationContext) else { return }
        DispatchQueue.main.async { self.onBackgroundWatchStatus?(status) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let info = WCCoding.decode(WatchRecordingInfo.self, from: file.metadata) else {
            logger.error("Received a file without metadata")
            return
        }
        // The system deletes `file.fileURL` when this method returns: move it now.
        let destination = SessionStore.watchAudioURL(for: info.sessionID, fileExtension: info.fileExtension)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            Journal.log("moving watch audio for \(info.sessionID) failed: \(error.localizedDescription)")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        Journal.log(String(format: "watch audio for %@ arrived: %@, %.1f s, %d KB", info.sessionID.uuidString, info.format.rawValue, info.duration, size / 1024))
        logger.info("Watch audio for \(info.sessionID, privacy: .public): \(info.format.rawValue, privacy: .public), \(info.sampleRate) Hz (hardware \(info.hardwareSampleRate) Hz), \(info.duration, format: .fixed(precision: 1)) s, \(info.clockSamples.count) clock samples")
        DispatchQueue.main.async { self.onAudioFile?(info, destination) }
    }

    private func notifyStateChange() {
        DispatchQueue.main.async { self.onStateChange?() }
    }
}
