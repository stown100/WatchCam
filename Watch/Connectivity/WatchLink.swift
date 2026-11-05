import Foundation
import WatchConnectivity

/// Watch side of WatchConnectivity.
///
/// WCSession is the system channel between the paired iPhone and Watch apps. Delegate
/// callbacks arrive on a background queue; this class hops to the main queue before
/// calling back into the model.
final class WatchLink: NSObject, WCSessionDelegate {
    /// Phone asks to start. The reply must be called exactly once.
    var onStartCommand: (@MainActor (UUID, WatchAudioFormat, @escaping (WCReply) -> Void) -> Void)?
    var onStopCommand: (@MainActor (UUID) -> Void)?
    var onContext: (@MainActor (PhoneContext) -> Void)?
    var onActivated: (@MainActor () -> Void)?
    var onPreviewFrame: (@MainActor (Data) -> Void)?
    var onReachabilityChange: (@MainActor (Bool) -> Void)?
    /// A file transfer ended. `error == nil` means the phone has the file.
    var onTransferFinished: (@MainActor (UUID, Error?) -> Void)?

    private let session = WCSession.default

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    var isReachable: Bool {
        session.activationState == .activated && session.isReachable
    }

    var outstandingTransfers: [WCSessionFileTransfer] {
        session.outstandingFileTransfers
    }

    /// Sends a live message. `reply` runs on main with `nil` on error or timeout, plus the
    /// host time the reply arrived (taken before hopping to main, for clock sync).
    func send(
        _ message: WCMessage,
        timeout: TimeInterval = 4,
        reply: @escaping @MainActor (WCReply?, Double) -> Void
    ) {
        let once = OnceGuard<(WCReply?, Double)> { value in
            DispatchQueue.main.async { reply(value.0, value.1) }
        }
        guard session.activationState == .activated else {
            once.fire((nil, HostClock.now()))
            return
        }
        session.sendMessageData(WCCoding.encode(message), replyHandler: { data in
            let receivedAt = HostClock.now()
            once.fire((WCCoding.decode(WCReply.self, from: data), receivedAt))
        }, errorHandler: { _ in
            once.fire((nil, HostClock.now()))
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.fire((nil, HostClock.now())) }
    }

    /// Queued delivery that survives disconnection; used when a live message fails.
    func sendQueued(_ message: WCMessage) {
        guard session.activationState == .activated else { return }
        session.transferUserInfo(WCCoding.dictionary(message))
    }

    func transfer(_ info: WatchRecordingInfo, from url: URL) {
        guard session.activationState == .activated else { return }
        session.transferFile(url, metadata: WCCoding.dictionary(info))
    }

    var receivedContext: PhoneContext? {
        WCCoding.decode(PhoneContext.self, from: session.receivedApplicationContext)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = receivedContext
        let reachable = session.isReachable
        DispatchQueue.main.async {
            if let context { self.onContext?(context) }
            self.onReachabilityChange?(reachable)
            self.onActivated?()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.onReachabilityChange?(reachable) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let respond: (WCReply) -> Void = { replyHandler(WCCoding.encode($0)) }
        if messageData.starts(with: WCCoding.jpegSignature) {
            // Answer at once: the phone waits for this before sending the next frame.
            respond(.ok)
            DispatchQueue.main.async { self.onPreviewFrame?(messageData) }
            return
        }
        guard let message = WCCoding.decode(WCMessage.self, from: messageData) else {
            respond(.failed(.audioFailed))
            return
        }
        DispatchQueue.main.async {
            switch message {
            case let .startRecording(sessionID, format):
                if let handler = self.onStartCommand {
                    handler(sessionID, format, respond)
                } else {
                    respond(.failed(.watchAppNotActive))
                }
            case let .stopRecording(sessionID):
                self.onStopCommand?(sessionID)
                respond(.ok)
            default:
                respond(.ok)
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context = WCCoding.decode(PhoneContext.self, from: applicationContext) else { return }
        DispatchQueue.main.async { self.onContext?(context) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let message = WCCoding.decode(WCMessage.self, from: userInfo),
              case let .stopRecording(sessionID) = message else { return }
        DispatchQueue.main.async { self.onStopCommand?(sessionID) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let info = WCCoding.decode(WatchRecordingInfo.self, from: fileTransfer.file.metadata) else { return }
        DispatchQueue.main.async { self.onTransferFinished?(info.sessionID, error) }
    }
}
