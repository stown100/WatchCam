import CoreMedia
import Foundation
import Observation

/// Video capture options.
struct CaptureSettings: Codable, Equatable {
    enum Resolution: String, Codable, CaseIterable, Identifiable {
        case uhd4K
        case fullHD

        var id: String { rawValue }
        var title: String { self == .uhd4K ? "4K" : "1080p" }
        var dimensions: CMVideoDimensions {
            self == .uhd4K ? CMVideoDimensions(width: 3840, height: 2160) : CMVideoDimensions(width: 1920, height: 1080)
        }
    }

    enum Codec: String, Codable, CaseIterable, Identifiable {
        case hevc
        case h264

        var id: String { rawValue }
        var title: String { self == .hevc ? "HEVC" : "H.264" }
    }

    enum Stabilization: String, Codable, CaseIterable, Identifiable {
        /// Best mode the format supports, without the extra crop of "enhanced".
        case auto
        case off
        case standard
        case cinematic
        /// Strongest stabilization (iOS 18+), noticeably narrower field of view.
        case enhanced

        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Авто (лучшая)"
            case .off: "Выключена"
            case .standard: "Стандартная"
            case .cinematic: "Кинематографическая"
            case .enhanced: "Усиленная"
            }
        }
    }

    static let frameRates = [24, 30, 60]

    var resolution: Resolution = .uhd4K
    var frameRate: Int = 30
    var codec: Codec = .hevc
    /// 10-bit HLG. Forces HEVC.
    var hdr = false
    var stabilization: Stabilization = .auto
    /// Small frame preview on the watch (adds a second, preview-sized video output).
    var watchPreview = true

    var summary: String {
        var parts = [resolution.title, "\(frameRate)", hdr ? "HDR" : codec.title]
        if stabilization == .off { parts.append("без стаб.") }
        return parts.joined(separator: " · ")
    }
}

/// All user preferences, persisted in UserDefaults as one JSON blob.
@MainActor @Observable
final class AppSettings {
    struct Values: Codable, Equatable {
        var capture = CaptureSettings()
        var watchAudioFormat: WatchAudioFormat = .aac
        /// Save to Photos as soon as the clip is synced.
        var autoSaveToPhotos = true
        /// Keep the iPhone's own audio as a second (disabled) track.
        var includePhoneAudioTrack = false
        /// After saving to Photos, delete the original video and watch audio too.
        var deleteSourcesAfterSave = false
    }

    var values: Values {
        didSet {
            guard values != oldValue else { return }
            if let data = try? JSONEncoder().encode(values) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private static let key = "settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Values.self, from: data) {
            values = stored
        } else {
            values = Values()
        }
    }
}
