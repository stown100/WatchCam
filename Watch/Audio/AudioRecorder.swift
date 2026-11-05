import AVFoundation
import Accelerate
import os

/// Records the watch microphone into a CAF file with AVAudioEngine.
///
/// AVAudioEngine (rather than AVAudioRecorder) gives a host-clock timestamp for every buffer,
/// which tells exactly when the first sample was captured and lets us fill interruptions
/// with silence so the file timeline never drifts from real time.
///
/// The file is always uncompressed PCM. Compressed audio needs a final step to become readable,
/// and that step doesn't happen if the app dies. PCM stays readable up to the last write, and it
/// costs almost no CPU, which matters while running in the background.
final class AudioRecorder {
    struct Result {
        var url: URL
        var sampleRate: Double
        var hardwareSampleRate: Double
        var startHostTime: Double
        var startWallTime: Date
        var duration: Double
        var silenceInserted: Double
        var gaps: [AudioGap]
    }

    enum RecorderError: LocalizedError {
        case noInput
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .noInput: "Микрофон недоступен."
            case .alreadyRecording: "Запись уже идёт."
            }
        }
    }

    /// No microphone data for this long, in seconds, means capture has stopped.
    static let stallTime = 2.0

    /// Input level in dBFS, delivered on the main queue about 10 times per second.
    var onLevel: ((Float) -> Void)?

    private let logger = Logger(subsystem: "WatchCam", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Guarded by `lock`: touched from the tap thread and from the main thread.
    private var file: AVAudioFile?
    private var url: URL?
    private var hardwareSampleRate: Double = 0
    private var startHostTime: Double?
    private var startWallTime: Date?
    private var nextExpectedHostTime: Double?
    private var framesWritten: AVAudioFramePosition = 0
    private var silenceFrames: AVAudioFramePosition = 0
    private var gaps: [AudioGap] = []
    private var lastLevelTime: Double = 0
    private var lastBufferTime: Double = 0
    private var writeFailures = 0

    private var observers: [NSObjectProtocol] = []

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    var isEngineRunning: Bool { engine.isRunning }

    /// Host time of the first captured sample, once known.
    var firstSampleHostTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return startHostTime
    }

    /// How long the microphone has been quiet, counted from the start. `nil` when not recording.
    var secondsSinceLastBuffer: Double? {
        lock.lock()
        defer { lock.unlock() }
        return file == nil ? nil : HostClock.now() - lastBufferTime
    }

    /// The recording so far. `nil` until the first sample arrives.
    var progress: Result? {
        lock.lock()
        defer { lock.unlock() }
        return makeResult()
    }

    func start(url: URL) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // watchOS doesn't allow choosing the sample rate: we record at whatever the hardware delivers
        // (logged below and sent to the phone in the file metadata).
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        logger.info("Audio session sample rate: \(session.sampleRate) Hz, input format: \(inputFormat.description, privacy: .public)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInput }

        let file = try Self.makeFile(url: url, sampleRate: inputFormat.sampleRate)
        Journal.log("recording to \(url.lastPathComponent) at \(inputFormat.sampleRate) Hz, protection \(Self.protection(of: url))")

        lock.lock()
        self.file = file
        self.url = url
        self.hardwareSampleRate = session.sampleRate
        startHostTime = nil
        startWallTime = nil
        nextExpectedHostTime = nil
        framesWritten = 0
        silenceFrames = 0
        gaps = []
        lastBufferTime = HostClock.now()
        writeFailures = 0
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, time in
            self?.handle(buffer, at: time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            self.file = nil
            lock.unlock()
            throw error
        }
        observeInterruptions()
    }

    func stop() -> Result? {
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let file = self.file
        let result = makeResult()
        self.file = nil
        lock.unlock()

        // Closing the file writes the final header.
        if #available(watchOS 11.0, *) {
            file?.close()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return result
    }

    /// Caller holds `lock`.
    private func makeResult() -> Result? {
        guard let url, let file, let startHostTime, let startWallTime else { return nil }
        let rate = file.processingFormat.sampleRate
        return Result(
            url: url,
            sampleRate: rate,
            hardwareSampleRate: hardwareSampleRate,
            startHostTime: startHostTime,
            startWallTime: startWallTime,
            duration: Double(framesWritten) / rate,
            silenceInserted: Double(silenceFrames) / rate,
            gaps: gaps
        )
    }

    // MARK: - Tap

    private func handle(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let rate = buffer.format.sampleRate
        let hostTime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : HostClock.now()
        guard let samples = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        lastBufferTime = HostClock.now()

        if startHostTime == nil {
            startHostTime = hostTime
            startWallTime = Date().addingTimeInterval(hostTime - HostClock.now())
        } else if let expected = nextExpectedHostTime, hostTime - expected > 0.05 {
            // The engine was interrupted: pad with silence so later audio stays in place.
            writeSilence(frames: AVAudioFramePosition((hostTime - expected) * rate), to: file)
        }
        nextExpectedHostTime = hostTime + Double(frameCount) / rate

        // The file is mono: take the first channel.
        guard let mono = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        mono.frameLength = AVAudioFrameCount(frameCount)
        mono.floatChannelData![0].update(from: samples, count: frameCount)
        do {
            try file.write(from: mono)
            framesWritten += AVAudioFramePosition(frameCount)
        } catch {
            writeFailures += 1
            if writeFailures <= 3 || writeFailures % 100 == 0 {
                Journal.log("write failed (\(writeFailures) so far): \(error.localizedDescription)")
            }
        }

        if hostTime - lastLevelTime >= 0.1 {
            lastLevelTime = hostTime
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
            let level = 20 * log10(max(rms, 1e-6))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
    }

    /// Caller holds `lock`.
    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) {
        let rate = file.processingFormat.sampleRate
        gaps.append(AudioGap(start: Double(framesWritten) / rate, duration: Double(frames) / rate))
        let chunk: AVAudioFramePosition = 4_096
        var remaining = frames
        while remaining > 0 {
            let count = min(chunk, remaining)
            guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
            silence.frameLength = AVAudioFrameCount(count)
            silence.floatChannelData![0].update(repeating: 0, count: Int(count))
            try? file.write(from: silence)
            remaining -= count
        }
        framesWritten += frames
        silenceFrames += frames
        Journal.log(String(format: "microphone came back: %.1f s of silence inserted", Double(frames) / rate))
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init) == .began
            Journal.log("audio interruption \(began ? "began" : "ended"), reason \(reason.map(String.init) ?? "none")")
            guard let self, self.isRecording, !began, !self.engine.isRunning else { return }
            self.restartEngine()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Journal.log("audio engine configuration changed")
            guard let self, self.isRecording, !self.engine.isRunning else { return }
            self.restartEngine()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Journal.log("audio route changed, reason \(reason.map(String.init) ?? "none")")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Journal.log("audio services were reset")
        })
    }

    /// Starts the microphone again if it went quiet.
    ///
    /// watchOS only allows this while the app is on screen, so it can't help in the background:
    /// the caller tries when the user comes back. Until then the iPhone is told, and the gap
    /// gets filled from the iPhone's own sound afterwards.
    func restartIfStalled() {
        guard let quiet = secondsSinceLastBuffer, quiet >= Self.stallTime else { return }
        restartEngine()
    }

    private func restartEngine() {
        do {
            if engine.isRunning { engine.stop() }
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            Journal.log("engine restarted")
        } catch {
            Journal.log("engine restart failed: \(error.localizedDescription)")
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - File

    private static func makeFile(url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        // The file must stay writable after the watch locks.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return file
    }

    private static func protection(of url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.protectionKey] as? FileProtectionType)?.rawValue ?? "unknown"
    }

    /// Makes a finished recording smaller for the trip to the phone.
    /// - Returns: `false` if this sample rate has no AAC encoder configuration.
    static func compressToAAC(input: URL, output: URL) throws -> Bool {
        let source = try AVAudioFile(forReading: input)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable,
            AVEncoderAudioQualityForVBRKey: AVAudioQuality.max.rawValue,
        ]
        guard let destination = try? AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else { return false }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            try destination.write(from: buffer)
        }
        // Closing the file makes it readable. Before watchOS 11 that happens when it's released.
        if #available(watchOS 11.0, *) {
            destination.close()
        }
        return true
    }
}
