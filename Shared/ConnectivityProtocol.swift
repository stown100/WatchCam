import Foundation

/// Audio format the watch sends its recording in. While recording it always writes PCM,
/// because that stays readable if the app dies. AAC is made after a clean stop.
enum WatchAudioFormat: String, Codable, CaseIterable, Identifiable {
    /// AAC in CAF, variable bit rate at maximum quality. Small files, fast transfer.
    case aac
    /// 16-bit PCM in CAF. Lossless, about 6 MB per minute at 48 kHz.
    case pcm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aac: "AAC (рекомендуется)"
        case .pcm: "Без сжатия (PCM)"
        }
    }
}

/// One NTP-style round trip. The watch is the client, the phone is the server.
/// Values are seconds on each device's `HostClock`.
struct ClockSample: Codable, Equatable {
    /// Watch: heartbeat sent.
    var t1: Double
    /// Phone: heartbeat received.
    var t2: Double
    /// Phone: reply sent.
    var t3: Double
    /// Watch: reply received.
    var t4: Double

    var delay: Double { (t4 - t1) - (t3 - t2) }
}

/// What the watch reports about itself in every heartbeat.
struct WatchStatus: Codable, Equatable {
    var isAppActive: Bool
    var isRecording: Bool
    var sessionID: UUID?
    var recordingStartedAt: Date?
    /// Input level, dBFS.
    var levelDB: Float?
    var pendingTransfers: Int
    /// 0...1 progress of the current file transfer, if any.
    var transferProgress: Double?
    /// The watch is on screen and would like small preview frames.
    var wantsPreview: Bool
    /// While recording: whether the microphone is really delivering sound.
    var isCapturing: Bool?
}

/// What the phone reports back to the watch.
struct PhoneStatus: Codable, Equatable {
    var isAppActive: Bool
    var isCameraReady: Bool
    var isRecording: Bool
    var sessionID: UUID?
    /// Sessions that are over on the phone. If the watch is still recording one of them, it stops.
    var stoppedSessionIDs: [UUID]
    /// Camera zoom in "Camera app" units (0.5× … 15×).
    var zoom: Double
    var minZoom: Double
    var maxZoom: Double
    /// Values the Digital Crown stops at (1×, 2×, 3×…).
    var zoomSteps: [Double]
    /// Focus set by hand on the phone's screen; `nil` while it is automatic.
    /// Optional, so a watch app and a phone app from different builds still understand each other.
    var focus: PhoneFocus? = nil
}

/// Focus the user set by touching the phone's screen. The phone often stands with its screen
/// turned away, so the watch is the only place to notice a touch that wasn't meant.
enum PhoneFocus: String, Codable {
    /// A tapped point: still automatic, but aimed there until the scene changes.
    case point
    /// Long press: focus and exposure stay where they are, whatever happens in the frame.
    case locked
}

/// Settings the phone pushes to the watch through the application context.
struct PhoneContext: Codable, Equatable {
    var audioFormat: WatchAudioFormat
    var stoppedSessionIDs: [UUID]
}

enum FailureReason: String, Codable, Error {
    case watchAppNotActive
    case watchBusy
    case microphoneDenied
    case audioFailed
    case phoneAppNotActive
    case cameraNotReady
    case phoneBusy
    case unreachable

    var message: String {
        switch self {
        case .watchAppNotActive: "Откройте WatchCam на часах: поднимите запястье и коснитесь иконки приложения."
        case .watchBusy: "Часы уже записывают другую сессию."
        case .microphoneDenied: "Нет доступа к микрофону часов. Разрешите его в настройках часов: Конфиденциальность → Микрофон."
        case .audioFailed: "Не удалось запустить микрофон часов."
        case .phoneAppNotActive: "Откройте WatchCam на iPhone: камера работает, только когда приложение на экране."
        case .cameraNotReady: "Камера iPhone ещё не готова."
        case .phoneBusy: "iPhone уже записывает."
        case .unreachable: "Откройте WatchCam на часах: связь с iPhone есть, только пока приложение на экране. Если не помогает, проверьте, что iPhone рядом и Bluetooth включён."
        }
    }
}

/// Live messages, sent with `sendMessageData` as JSON and answered with `WCReply`.
/// Preview frames from the phone are the exception: raw JPEG bytes, without the JSON/base64 overhead.
enum WCMessage: Codable {
    // Phone → watch
    case startRecording(sessionID: UUID, format: WatchAudioFormat)
    case stopRecording(sessionID: UUID)
    // Watch → phone
    case requestStart(sessionID: UUID)
    case requestStop(sessionID: UUID)
    /// Doubles as an NTP ping: `sentAt` is the watch's t1.
    case heartbeat(WatchStatus, sentAt: Double)
    /// Digital Crown zoom, in "Camera app" units.
    case setZoom(Double)
    /// Drop a focus point or lock set on the phone's screen: back to automatic.
    case resetFocus
    /// The watch has nothing to send for this take: the phone shouldn't wait for it.
    case recordingLost(sessionID: UUID)
}

enum WCReply: Codable {
    case ok
    case failed(FailureReason)
    /// Heartbeat answer carrying the phone's t2/t3.
    case phoneStatus(PhoneStatus, receivedAt: Double, sentAt: Double)
}

/// A stretch of a recording's file that holds inserted silence instead of sound.
struct AudioGap: Codable, Equatable {
    /// Seconds from the start of the file.
    var start: Double
    var duration: Double
}

/// Metadata attached to the audio file the watch transfers.
struct WatchRecordingInfo: Codable, Equatable {
    var sessionID: UUID
    var format: WatchAudioFormat
    var fileExtension: String
    var sampleRate: Double
    /// Rate reported by the audio session, logged for diagnostics.
    var hardwareSampleRate: Double
    /// Watch host-clock time of the first sample in the file.
    var audioStartHostTime: Double
    /// Watch wall-clock time of the first sample (fallback if no clock samples).
    var audioStartWallTime: Date
    var duration: Double
    /// Silence inserted to cover gaps (interruptions), so the file timeline stays continuous.
    var silenceInserted: Double
    /// Best NTP round trips taken while recording.
    var clockSamples: [ClockSample]
    /// Where that silence is.
    var gaps: [AudioGap]?
    /// The app died during the recording, and this is what was saved up to that point.
    var wasInterrupted: Bool?
}

/// Wraps Codable values into WatchConnectivity property-list payloads.
enum WCCoding {
    static let payloadKey = "payload"
    /// Every JPEG starts with these bytes; JSON messages start with `{`.
    static let jpegSignature: [UInt8] = [0xFF, 0xD8]

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    static func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        [payloadKey: encode(value)]
    }

    static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]?) -> T? {
        guard let data = dictionary?[payloadKey] as? Data else { return nil }
        return decode(type, from: data)
    }
}

/// Calls a completion handler exactly once, whichever comes first: the result or the timeout.
final class OnceGuard<Value> {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func fire(_ value: Value) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        handler?(value)
    }
}
