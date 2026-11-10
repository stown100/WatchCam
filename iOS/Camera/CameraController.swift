import AVFoundation
import CoreImage
import Observation
import UIKit
import os

/// Owns the capture pipeline: camera + iPhone microphone → AVCaptureMovieFileOutput → .mov file.
///
/// AVCaptureMovieFileOutput is the same recorder the Camera app is built on, so encoding,
/// HDR and stabilization quality match it. Session work runs on `sessionQueue` because
/// AVFoundation configuration calls block; observable properties change only on main.
@Observable
final class CameraController: NSObject {
    enum Status: Equatable {
        case notConfigured
        case unauthorized
        case failed(String)
        case ready
    }

    private(set) var status: Status = .notConfigured
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var position: AVCaptureDevice.Position = .back
    /// Zoom values shown on the lens buttons, in "Camera app" units (0.5×, 1×, 2×, 3×).
    private(set) var zoomPresets: [CGFloat] = []
    /// Where the Digital Crown stops: the lens buttons plus digital 5× and 8×.
    private(set) var zoomSteps: [CGFloat] = []
    private(set) var displayZoom: CGFloat = 1
    private(set) var minDisplayZoom: CGFloat = 1
    private(set) var maxDisplayZoom: CGFloat = 1
    /// What the session actually runs, e.g. "3840×2160 · 30 к/с · HEVC · HDR".
    private(set) var activeFormatSummary = ""
    private(set) var isHDRActive = false
    /// Why the camera is paused (phone call, another app, overheating), if it is.
    private(set) var interruptionMessage: String?
    /// Physical device rotation for counter-rotating icons (0 = landscape right, 90 = portrait).
    private(set) var deviceRotationAngle: CGFloat = 90
    /// The user tapped a focus/exposure point (otherwise the camera meters the whole frame).
    private(set) var hasUserFocusPoint = false
    /// AE/AF lock from a long press.
    private(set) var isFocusLocked = false
    /// Exposure compensation, EV.
    private(set) var exposureBias: Float = 0
    private(set) var exposureBiasRange: ClosedRange<Float> = -2...2

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "WatchCam.camera")
    @ObservationIgnored private let logger = Logger(subsystem: "WatchCam", category: "Camera")
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()

    /// Small JPEG frames for the watch, delivered on a background queue.
    @ObservationIgnored var onPreviewFrame: ((Data) -> Void)?
    /// Asked before encoding: is the link to the watch free for another frame?
    @ObservationIgnored var canSendPreviewFrame: (() -> Bool)?
    @ObservationIgnored private let previewOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let previewQueue = DispatchQueue(label: "WatchCam.preview")
    @ObservationIgnored private let previewLock = NSLock()
    // Guarded by `previewLock`.
    @ObservationIgnored private var previewWanted = false
    @ObservationIgnored private var previewInterval = CameraController.previewInterval
    @ObservationIgnored private var previewRotationAngle: CGFloat = 90
    @ObservationIgnored private var previewSteps = PreviewSteps()
    // Preview queue only.
    @ObservationIgnored private var lastPreviewTime: Double = 0
    /// Made with the first frame, not at launch: iOS may start the app in the background
    /// long before it is opened, and a context made then is never checked again.
    @ObservationIgnored private var previewContext: CIContext?
    @ObservationIgnored private var previewEncodeFailures = 0

    // Session-queue state.
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var settings = CaptureSettings()
    /// Lens position at the last journal line about focus, to log only real moves.
    @ObservationIgnored private var journaledLensPosition: Float = -1
    /// Waits for the lens to come to rest before a "focus moved" line is written.
    @ObservationIgnored private var lensRestCheck: DispatchWorkItem?
    /// Counts focus changes made by the user, so a lock still waiting for the exposure to settle
    /// can tell that a newer tap or a reset has replaced it.
    @ObservationIgnored private var focusChangeCount = 0

    // Main-thread state.
    @ObservationIgnored private var configureRequested = false
    @ObservationIgnored private var zoomMultiplier: CGFloat = 1
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var deviceObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?
    @ObservationIgnored private var recordingDelegate: RecordingDelegate?

    override init() {
        super.init()
        observeSessionNotifications()
    }

    // MARK: - Setup

    /// Asks for camera/microphone access (first launch only) and builds the session.
    func configure(with settings: CaptureSettings) {
        guard status == .notConfigured, !configureRequested else { return }
        configureRequested = true
        Task { @MainActor in
            let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
            let audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard videoAllowed else {
                status = .unauthorized
                return
            }
            sessionQueue.async { [self] in
                buildSession(settings: settings, includeAudio: audioAllowed)
            }
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = videoInput?.device { makeRotationCoordinator(for: device) }
    }

    func startRunning() {
        sessionQueue.async { [self] in
            guard isConfigured, !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            if !running { Journal.log("camera didn't start") }
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func stopRunning() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// Re-applies format, frame rate, codec, HDR and stabilization.
    func apply(_ settings: CaptureSettings) {
        guard !isRecording else { return }
        sessionQueue.async { [self] in
            self.settings = settings
            guard isConfigured, let device = videoInput?.device else { return }
            session.beginConfiguration()
            applyCurrentSettings(to: device)
            updatePreviewOutput()
            session.commitConfiguration()
            enforceHardwareBudget()
            publishDeviceState(device)
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        sessionQueue.async { [self] in
            guard isConfigured,
                  let device = Self.videoDevice(for: newPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            let oldInput = videoInput
            if let oldInput { session.removeInput(oldInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            } else if let oldInput {
                session.addInput(oldInput)
            }
            if let device = videoInput?.device { applyCurrentSettings(to: device) }
            updatePreviewOutput()
            session.commitConfiguration()
            enforceHardwareBudget()
            if let device = videoInput?.device { publishDeviceState(device) }
        }
    }

    private func buildSession(settings: CaptureSettings, includeAudio: Bool) {
        self.settings = settings
        session.beginConfiguration()
        // `.inputPriority` lets us pick the device format ourselves (resolution, fps, HDR).
        session.sessionPreset = .inputPriority
        // We set the color space explicitly (HLG for HDR); don't let the session override it.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard let device = Self.videoDevice(for: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            fail("Камера недоступна")
            return
        }
        session.addInput(input)
        videoInput = input

        if includeAudio,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        } else {
            logger.warning("Recording without iPhone audio: fine sync will fall back to clocks")
        }

        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            fail("Не удалось настроить запись видео")
            return
        }
        session.addOutput(movieOutput)
        applyCurrentSettings(to: device)
        updatePreviewOutput()
        session.commitConfiguration()
        enforceHardwareBudget()

        isConfigured = true
        session.startRunning()
        let running = session.isRunning
        let standIns = device.fallbackPrimaryConstituentDevices.map(Self.lensName).joined(separator: ", ")
        Journal.log("camera set up, running \(running), watch preview output \(session.outputs.contains(previewOutput) ? "on" : "off")"
            + ", lenses that may stand in for a longer one: \(standIns.isEmpty ? "none" : standIns)")
        publishDeviceState(device)
        DispatchQueue.main.async {
            self.status = .ready
            self.isRunning = running
        }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DispatchQueue.main.async { self.status = .failed(message) }
    }

    // MARK: - Watch preview

    /// Session queue, inside begin/commitConfiguration. Adds or removes the preview-sized video output.
    private func updatePreviewOutput() {
        let attached = session.outputs.contains(previewOutput)
        if settings.watchPreview, !attached {
            previewOutput.alwaysDiscardsLateVideoFrames = true
            previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            previewOutput.automaticallyConfiguresOutputBufferDimensions = false
            previewOutput.deliversPreviewSizedOutputBuffers = true
            previewOutput.setSampleBufferDelegate(self, queue: previewQueue)
            if session.canAddOutput(previewOutput) { session.addOutput(previewOutput) }
        } else if !settings.watchPreview, attached {
            session.removeOutput(previewOutput)
        }
    }

    /// Since iOS 16 a movie output and a video data output can run together, but they share the
    /// camera's bandwidth. If the session goes over budget (e.g. 4K60 HDR), the recording wins.
    private func enforceHardwareBudget() {
        guard session.outputs.contains(previewOutput), session.hardwareCost > 1 else { return }
        Journal.log("hardware cost \(session.hardwareCost) > 1: watch preview off for this format")
        session.beginConfiguration()
        session.removeOutput(previewOutput)
        session.commitConfiguration()
    }

    /// Upper limit for the watch preview: about 8 frames per second.
    static let previewInterval = 0.125
    /// While a file from the watch is on its way: the frames share the link with it.
    static let previewIntervalDuringTransfer = 1.0

    /// Any thread. Frames are produced only while the watch app is on screen.
    func setPreviewWanted(_ wanted: Bool, interval: Double = CameraController.previewInterval) {
        previewLock.lock()
        previewWanted = wanted
        previewInterval = interval
        previewLock.unlock()
    }

    /// When each step of the watch preview last worked, in host-clock seconds.
    /// Shows which step stopped when the watch gets no picture.
    struct PreviewSteps {
        /// The camera delivered a preview-sized frame.
        var frame: Double = 0
        /// A frame was due and the link was free, so encoding began.
        var attempt: Double = 0
        /// The frame became a JPEG and went to the link.
        var encoded: Double = 0
    }

    var previewProgress: PreviewSteps {
        previewLock.lock()
        defer { previewLock.unlock() }
        return previewSteps
    }

    /// Takes the preview output out of the session and puts it back, for when the camera stopped
    /// delivering its frames. Not while recording: changing the session could disturb the movie.
    func reattachPreviewOutput() {
        sessionQueue.async { [self] in
            guard isConfigured, !movieOutput.isRecording else { return }
            session.beginConfiguration()
            if session.outputs.contains(previewOutput) { session.removeOutput(previewOutput) }
            updatePreviewOutput()
            session.commitConfiguration()
            enforceHardwareBudget()
            Journal.log("watch preview output re-attached: \(session.outputs.contains(previewOutput) ? "on" : "off")")
        }
    }

    // MARK: - Device & format

    /// Back: the virtual triple camera, so zooming switches lenses seamlessly like in the Camera app.
    static func videoDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) { return device }
        }
        return nil
    }

    /// Session queue, inside begin/commitConfiguration.
    private func applyCurrentSettings(to device: AVCaptureDevice) {
        guard let (format, hdr) = Self.bestFormat(for: device, settings: settings) else {
            logger.error("No format for \(self.settings.summary, privacy: .public)")
            return
        }
        let zoom = Self.zoomLayout(for: device)
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let colorSpace: AVCaptureColorSpace = hdr ? .HLG_BT2020 : .sRGB
            if format.supportedColorSpaces.contains(colorSpace) {
                device.activeColorSpace = colorSpace
            }
            // Fixed frame rate: min == max duration.
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            // Slower, less "hunting" focus changes: better for video.
            // Set before the focus mode: it only takes effect when the mode is set.
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            // Continuous autofocus puts faces first by itself (iOS 15.4+, "face-driven autofocus").
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = true
            // The ultra wide lens must not stand in for the main one. iOS does that when something
            // comes closer than the main lens can focus, and during a take it doesn't switch back:
            // the rest of the take is a blown-up crop of the ultra wide, soft all over.
            // The main lens may still stand in for the telephoto (dim light, close subject).
            let standIns = device.supportedFallbackPrimaryConstituentDevices.filter { $0.deviceType != .builtInUltraWideCamera }
            if standIns.count != device.fallbackPrimaryConstituentDevices.count {
                device.fallbackPrimaryConstituentDevices = standIns
            }
            device.videoZoomFactor = min(max(zoom.defaultFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            logger.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }

        var codec: AVVideoCodecType = .h264
        var stabilization: AVCaptureVideoStabilizationMode = .off
        if let connection = movieOutput.connection(with: .video) {
            codec = (settings.codec == .hevc || hdr) ? .hevc : .h264
            if movieOutput.availableVideoCodecTypes.contains(codec) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
            }
            if connection.isVideoStabilizationSupported {
                stabilization = Self.stabilizationMode(for: settings.stabilization, format: format)
                connection.preferredVideoStabilizationMode = stabilization
            }
            // Record the front camera the way people see it (not mirrored), like the Camera app default.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let summary = [
            "\(dimensions.width)×\(dimensions.height)",
            "\(settings.frameRate) к/с",
            codec == .hevc ? "HEVC" : "H.264",
            hdr ? "HDR HLG" : "SDR",
            "стаб. \(Self.describe(stabilization))",
        ].joined(separator: " · ")
        logger.info("Active format: \(summary, privacy: .public)")
        logger.info("Zoom quality: lens switch-overs \(device.virtualDeviceSwitchOverVideoZoomFactors, privacy: .public), sensor-crop factors \(format.secondaryNativeResolutionZoomFactors, privacy: .public), upscaling starts at \(format.videoZoomFactorUpscaleThreshold) (device units, 1× on screen = \(zoom.defaultFactor))")
        DispatchQueue.main.async {
            self.activeFormatSummary = summary
            self.isHDRActive = hdr
        }
    }

    /// Picks a format matching resolution and frame rate; 10-bit HLG if HDR is wanted and available.
    static func bestFormat(for device: AVCaptureDevice, settings: CaptureSettings) -> (AVCaptureDevice.Format, Bool)? {
        let target = settings.resolution.dimensions
        let fps = Double(settings.frameRate)
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == target.width && dimensions.height == target.height
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }

        func isTenBit(_ format: AVCaptureDevice.Format) -> Bool {
            CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        func score(_ format: AVCaptureDevice.Format) -> Int {
            var score = 0
            if format.isVideoStabilizationModeSupported(.cinematicExtended) { score += 8 }
            // Can switch to the centre of the 48 MP sensor at 2×, without digital upscaling.
            if !format.secondaryNativeResolutionZoomFactors.isEmpty { score += 6 }
            if !format.isVideoBinned { score += 4 }
            if CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { score += 2 }
            if format.isVideoHDRSupported { score += 1 }
            return score
        }

        if settings.hdr,
           let format = candidates.filter({ isTenBit($0) && $0.supportedColorSpaces.contains(.HLG_BT2020) }).max(by: { score($0) < score($1) }) {
            return (format, true)
        }
        if let format = candidates.filter({ !isTenBit($0) }).max(by: { score($0) < score($1) }) {
            return (format, false)
        }
        return candidates.first.map { ($0, false) }
    }

    static func stabilizationMode(for setting: CaptureSettings.Stabilization, format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode {
        var preferred: [AVCaptureVideoStabilizationMode]
        switch setting {
        case .off: return .off
        case .standard: preferred = [.standard]
        case .cinematic: preferred = [.cinematic, .standard]
        case .auto: preferred = [.cinematicExtended, .cinematic, .standard]
        case .enhanced:
            preferred = [.cinematicExtended, .cinematic, .standard]
            if #available(iOS 18.0, *) { preferred.insert(.cinematicExtendedEnhanced, at: 0) }
        }
        return preferred.first { format.isVideoStabilizationModeSupported($0) } ?? .off
    }

    static func describe(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: "выкл"
        case .standard: "стандарт"
        case .cinematic: "кино"
        case .cinematicExtended: "кино+"
        default:
            if #available(iOS 18.0, *), mode == .cinematicExtendedEnhanced { "усиленная" } else { "авто" }
        }
    }

    // MARK: - Zoom

    struct ZoomLayout {
        /// display zoom = device zoom factor × multiplier.
        var multiplier: CGFloat
        var presets: [CGFloat]
        var steps: [CGFloat]
        var minDisplay: CGFloat
        var maxDisplay: CGFloat
        /// Device factor that corresponds to 1× on screen.
        var defaultFactor: CGFloat
    }

    /// On the virtual triple camera `videoZoomFactor == 1` is the ultra wide lens (0.5× on screen),
    /// and `virtualDeviceSwitchOverVideoZoomFactors` say where it hands over to the next lens.
    static func zoomLayout(for device: AVCaptureDevice) -> ZoomLayout {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let lenses = device.constituentDevices.map(\.deviceType)
        let hasUltraWide = lenses.contains(.builtInUltraWideCamera)
        let hasTelephoto = lenses.contains(.builtInTelephotoCamera)
        let multiplier: CGFloat = (hasUltraWide && !switchOvers.isEmpty) ? 1 / switchOvers[0] : 1

        let minDisplay = device.minAvailableVideoZoomFactor * multiplier
        let telephoto = hasTelephoto ? switchOvers.last.map { ($0 * multiplier * 10).rounded() / 10 } : nil
        let maxDisplay = min(device.maxAvailableVideoZoomFactor * multiplier, max(10, (telephoto ?? 2) * 5))

        var presets: [CGFloat] = []
        if hasUltraWide { presets.append(0.5) }
        presets.append(1)
        if device.position == .back { presets.append(2) }
        if let telephoto, telephoto > 2.05 { presets.append(telephoto) }
        presets = presets.filter { $0 >= minDisplay - 0.01 && $0 <= maxDisplay + 0.01 }

        // 5× and 8× are digital where there's no such lens, but they're handy stops on the crown.
        let digitalSteps: [CGFloat] = device.position == .back ? [5, 8] : []
        let steps = Set(presets + digitalSteps.filter { $0 <= maxDisplay }).sorted()

        return ZoomLayout(multiplier: multiplier, presets: presets, steps: steps, minDisplay: minDisplay,
                          maxDisplay: maxDisplay, defaultFactor: 1 / multiplier)
    }

    /// Sets zoom in on-screen units. `animated` ramps smoothly (lens buttons, Digital Crown),
    /// otherwise jumps (pinch). `rate` is in doublings per second.
    func setZoom(_ display: CGFloat, animated: Bool, rate: Float = 6) {
        let clamped = min(max(display, minDisplayZoom), maxDisplayZoom)
        displayZoom = clamped
        let factor = clamped / zoomMultiplier
        sessionQueue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let target = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if animated {
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
        }
    }

    /// Session queue → main: zoom layout, KVO, rotation coordinator for the current device.
    private func publishDeviceState(_ device: AVCaptureDevice) {
        let layout = Self.zoomLayout(for: device)
        let position = device.position
        DispatchQueue.main.async { [self] in
            self.position = position
            zoomMultiplier = layout.multiplier
            zoomPresets = layout.presets
            zoomSteps = layout.steps
            minDisplayZoom = layout.minDisplay
            maxDisplayZoom = layout.maxDisplay
            displayZoom = device.videoZoomFactor * layout.multiplier

            deviceObservations = [
                device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
                    let factor = device.videoZoomFactor
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.displayZoom = factor * self.zoomMultiplier
                    }
                },
                // The triple camera changes lenses by itself: for zoom, and for a subject too close
                // or a scene too dark for the lens that the zoom asks for.
                device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] device, _ in
                    self?.sessionQueue.async { self?.journalFocus("camera lens changed", device: device, always: true) }
                },
                // The lens moved: once it has rested for a moment, note where it stopped, while a take
                // is being recorded. (`isAdjustingFocus` is no use for this: with smooth autofocus
                // it stayed silent while the lens travelled its whole range.)
                device.observe(\.lensPosition, options: [.new]) { [weak self] device, _ in
                    self?.sessionQueue.async {
                        guard let self, self.movieOutput.isRecording else { return }
                        self.lensRestCheck?.cancel()
                        let check = DispatchWorkItem { [weak self] in
                            guard let self, self.movieOutput.isRecording else { return }
                            self.journalFocus("focus moved", device: device, always: false)
                        }
                        self.lensRestCheck = check
                        self.sessionQueue.asyncAfter(deadline: .now() + 0.7, execute: check)
                    }
                },
            ]
            makeRotationCoordinator(for: device)

            hasUserFocusPoint = false
            isFocusLocked = false
            exposureBias = 0
            exposureBiasRange = max(device.minExposureTargetBias, -2)...min(device.maxExposureTargetBias, 2)
            // When the scene changes a lot, go back to metering the whole frame (unless locked).
            if let subjectAreaObserver { NotificationCenter.default.removeObserver(subjectAreaObserver) }
            subjectAreaObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: .main
            ) { [weak self] _ in
                guard let self, self.hasUserFocusPoint, !self.isFocusLocked else { return }
                self.resetFocus(because: "the scene changed")
            }
        }
    }

    // MARK: - Focus & exposure

    /// Tap: focus and meter at a point (continuous). Long press: same, then lock (AE/AF lock).
    /// - Parameter point: camera coordinates, (0,0) top-left to (1,1) bottom-right of the sensor.
    func focusAndExpose(at point: CGPoint, lock: Bool) {
        hasUserFocusPoint = true
        isFocusLocked = lock
        exposureBias = 0
        configureFocus(at: point, lock: lock, note: lock ? "focus and exposure locked by a long press" : "focus point set by a tap")
    }

    /// Back to automatic focus/exposure over the whole frame.
    func resetFocus(because reason: String = "the reset button") {
        hasUserFocusPoint = false
        isFocusLocked = false
        exposureBias = 0
        configureFocus(at: CGPoint(x: 0.5, y: 0.5), lock: false, note: "focus back to automatic (\(reason))")
    }

    func setExposureBias(_ bias: Float) {
        let clamped = min(max(bias, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        exposureBias = clamped
        sessionQueue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()
        }
    }

    private func configureFocus(at point: CGPoint, lock: Bool, note: String) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer {
                device.unlockForConfiguration()
                journalFocus(note, device: device, always: true)
            }
            focusChangeCount += 1
            // `.autoFocus` / `.autoExpose` adjust once and then hold: that is the lock.
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
            if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            if lock, device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                // A camera without `.autoExpose`: meter at the point, and hold once it has settled.
                if lock { lockExposureWhenSettled(device, change: focusChangeCount, since: HostClock.now()) }
            }
            device.setExposureTargetBias(0)
            device.isSubjectAreaChangeMonitoringEnabled = !lock
        }
    }

    /// Session queue. Checks every 0.1 s; gives the exposure 0.3 s to start moving
    /// and at most 2 s to stop.
    private func lockExposureWhenSettled(_ device: AVCaptureDevice, change: Int, since start: Double) {
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
            // A newer tap, a reset or another camera has taken over.
            guard change == focusChangeCount, device == videoInput?.device else { return }
            let waited = HostClock.now() - start
            guard waited >= 2 || (waited >= 0.3 && !device.isAdjustingExposure) else {
                return lockExposureWhenSettled(device, change: change, since: start)
            }
            guard device.isExposureModeSupported(.locked), (try? device.lockForConfiguration()) != nil else { return }
            device.exposureMode = .locked
            device.unlockForConfiguration()
            journalFocus("exposure locked", device: device, always: true)
        }
    }

    /// Session queue. `always: false` skips moves too small to change the picture.
    private func journalFocus(_ event: String, device: AVCaptureDevice, always: Bool) {
        guard always || abs(device.lensPosition - journaledLensPosition) >= 0.05 else { return }
        journaledLensPosition = device.lensPosition
        Journal.log("\(event): \(focusSummary(device))")
    }

    /// Session queue. Which lens is in use and how it focuses, for the journal.
    /// Lens position runs from 0 (as close as the lens can focus) to 1 (far).
    private func focusSummary(_ device: AVCaptureDevice) -> String {
        let mode = switch device.focusMode {
        case .continuousAutoFocus: "continuous"
        case .autoFocus: "focusing once"
        case .locked: "locked"
        @unknown default: "unknown"
        }
        let exposure = switch device.exposureMode {
        case .continuousAutoExposure: "continuous"
        case .autoExpose: "metering once"
        case .locked: "locked"
        case .custom: "manual"
        @unknown default: "unknown"
        }
        let point = device.focusPointOfInterest
        return String(
            format: "%@ lens, zoom %.1f×, focus %@ at (%.2f, %.2f), lens position %.2f, faces first %@, exposure %@",
            Self.lensName(device.activePrimaryConstituent ?? device),
            Double(device.videoZoomFactor * Self.zoomLayout(for: device).multiplier),
            mode, point.x, point.y, device.lensPosition,
            device.isFaceDrivenAutoFocusEnabled ? "on" : "off", exposure
        )
    }

    private static func lensName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: "ultra wide"
        case .builtInWideAngleCamera: "wide"
        case .builtInTelephotoCamera: "telephoto"
        default: device.localizedName
        }
    }

    /// Whether the current camera can shoot 10-bit HLG with these settings.
    func supportsHDR(_ settings: CaptureSettings) -> Bool {
        guard let device = Self.videoDevice(for: position) else { return false }
        var wanted = settings
        wanted.hdr = true
        return Self.bestFormat(for: device, settings: wanted)?.1 ?? false
    }

    // MARK: - Rotation

    /// RotationCoordinator tracks how the phone is physically held. The preview is rotated to stay
    /// level, and the same angle is written into the movie so the file plays upright.
    private func makeRotationCoordinator(for device: AVCaptureDevice) {
        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let connection = self?.previewLayer?.connection,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                guard let self else { return }
                self.previewLock.lock()
                self.previewRotationAngle = angle
                self.previewLock.unlock()
                DispatchQueue.main.async { self.deviceRotationAngle = angle }
            },
        ]
    }

    // MARK: - Recording

    /// Starts writing a movie.
    /// - Parameters:
    ///   - onStart: host-clock time of the start, and whether it's the exact first-frame timestamp.
    ///   - onFinish: `nil` if the file is usable (also after an interruption that finished it cleanly).
    func startRecording(
        to url: URL,
        onStart: @escaping @MainActor (Double, Bool) -> Void,
        onFinish: @escaping @MainActor (Error?) -> Void
    ) {
        guard !isRecording, status == .ready else { return }
        isRecording = true
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let delegate = RecordingDelegate(session: session, onStart: onStart) { [weak self] error in
            self?.isRecording = false
            self?.recordingDelegate = nil
            self?.sessionQueue.async {
                guard let self, let device = self.videoInput?.device else { return }
                self.journalFocus("take ends", device: device, always: true)
            }
            onFinish(error)
        }
        recordingDelegate = delegate

        sessionQueue.async { [self] in
            guard let connection = movieOutput.connection(with: .video) else {
                DispatchQueue.main.async { delegate.onFinish(CameraError.notReady) }
                return
            }
            if let angle, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if let device = videoInput?.device { journalFocus("take starts", device: device, always: true) }
            movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    enum CameraError: LocalizedError {
        case notReady

        var errorDescription: String? { "Камера не готова" }
    }

    // MARK: - Interruptions

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            Journal.log("camera interrupted, reason \(raw.map(String.init) ?? "none")")
            self?.interruptionMessage = Self.describe(reason)
            self?.isRunning = false
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            Journal.log("camera interruption ended")
            self?.interruptionMessage = nil
            self?.isRunning = true
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Journal.log("camera runtime error: \(error?.localizedDescription ?? "unknown") (\(error?.code.rawValue ?? 0))")
            // Media services were reset: the session must be restarted.
            if error?.code == .mediaServicesWereReset { startRunning() }
        })
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .audioDeviceInUseByAnotherClient: "Микрофон занят (звонок или другое приложение)"
        case .videoDeviceInUseByAnotherClient: "Камера занята другим приложением"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "Камера недоступна в режиме нескольких окон"
        case .videoDeviceNotAvailableDueToSystemPressure: "Камера остановлена: iPhone перегрелся"
        case .videoDeviceNotAvailableInBackground: "Камера работает только на экране"
        default: "Камера приостановлена"
        }
    }
}

/// Thread safety is manual: session state is only touched on `sessionQueue`, observable state only on main.
extension CameraController: @unchecked Sendable {}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Preview queue. Turns the newest frame into a small JPEG as soon as the link to the watch is free,
    /// so the picture updates as fast as the connection allows and frames never wait in a queue.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = HostClock.now()
        previewLock.lock()
        let wanted = previewWanted
        let interval = previewInterval
        let angle = previewRotationAngle
        previewSteps.frame = now
        previewLock.unlock()

        guard wanted, now - lastPreviewTime >= interval, canSendPreviewFrame?() == true,
              let sink = onPreviewFrame, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPreviewTime = now
        markPreviewStep(\.attempt, at: now)

        // Buffers come in sensor orientation; turn them the way the movie will play.
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(Self.orientation(forRotationAngle: angle))
        let scale = 220 / max(image.extent.width, image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = previewContext ?? CIContext()
        previewContext = context
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(
                  of: image, colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]
              ) else {
            // A context that keeps failing is dropped: the next frame makes a new one.
            previewEncodeFailures += 1
            if previewEncodeFailures >= 5 {
                previewEncodeFailures = 0
                previewContext = nil
                Journal.log("watch preview: JPEG encoding keeps failing, making a new Core Image context")
            }
            return
        }
        previewEncodeFailures = 0
        markPreviewStep(\.encoded, at: now)
        sink(jpeg)
    }

    private func markPreviewStep(_ step: WritableKeyPath<PreviewSteps, Double>, at time: Double) {
        previewLock.lock()
        previewSteps[keyPath: step] = time
        previewLock.unlock()
    }

    private static func orientation(forRotationAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle.rounded()) {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }
}

/// Receives AVCaptureMovieFileOutput callbacks for one recording.
private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private weak var session: AVCaptureSession?
    private let onStart: @MainActor (Double, Bool) -> Void
    let onFinish: @MainActor (Error?) -> Void

    init(session: AVCaptureSession, onStart: @escaping @MainActor (Double, Bool) -> Void, onFinish: @escaping @MainActor (Error?) -> Void) {
        self.session = session
        self.onStart = onStart
        self.onFinish = onFinish
    }

    /// iOS 17 – 18.1: only the callback time is known (within tens of milliseconds).
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = HostClock.now()
        DispatchQueue.main.async { self.onStart(now, false) }
    }

    /// iOS 18.2+: exact timestamp of the first written frame. When implemented, the method above isn't called.
    @available(iOS 18.2, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime, from connections: [AVCaptureConnection]) {
        var hostTime = startPTS
        if let clock = session?.synchronizationClock {
            hostTime = CMSyncConvertTime(startPTS, from: clock, to: CMClockGetHostTimeClock())
        }
        let seconds = hostTime.seconds
        DispatchQueue.main.async { self.onStart(seconds, true) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        var failure = error
        // Interruptions (calls, backgrounding, full disk) still produce a valid file.
        if let error = error as NSError?, (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true {
            failure = nil
        }
        DispatchQueue.main.async { self.onFinish(failure) }
    }
}
