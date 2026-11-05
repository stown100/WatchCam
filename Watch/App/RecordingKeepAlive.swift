import WatchKit

/// Keeps the app running during a recording, whether or not anyone is looking at the watch.
///
/// By default watchOS suspends an app soon after it leaves the screen. An extended runtime session
/// is the way to ask for more time, and the "physical therapy" type is the one that runs in the
/// background, up to an hour. It has to start while the app is on screen.
final class RecordingKeepAlive: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    /// Kept until the system confirms it ended. A new recording mustn't wait for that.
    private var endingSession: WKExtendedRuntimeSession?
    private var stopWhenStarted = false

    var isRunning: Bool { session?.state == .running }

    func start() {
        stopWhenStarted = false
        guard session == nil else { return }
        guard WKApplication.shared().applicationState == .active else {
            Journal.log("keep-alive not started: the app isn't on screen")
            return
        }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    func stop() {
        guard let session else { return }
        if session.state == .running {
            endingSession = session
            self.session = nil
            session.invalidate()
        } else {
            stopWhenStarted = true
        }
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let expires = extendedRuntimeSession.expirationDate?.description ?? "?"
        Journal.log("keep-alive started, expires \(expires)")
        DispatchQueue.main.async {
            if self.stopWhenStarted {
                self.stopWhenStarted = false
                self.stop()
            }
        }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Journal.log("keep-alive is about to expire")
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Journal.log("keep-alive ended: reason \(reason.rawValue), error \(error?.localizedDescription ?? "none")")
        DispatchQueue.main.async {
            if self.session === extendedRuntimeSession {
                self.session = nil
                self.stopWhenStarted = false
            }
            if self.endingSession === extendedRuntimeSession { self.endingSession = nil }
        }
    }
}
