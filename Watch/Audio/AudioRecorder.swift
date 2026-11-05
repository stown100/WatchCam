import AVFoundation
import Accelerate
import os

/// Records the watch microphone into a CAF file with AVAudioEngine.
///
/// AVAudioEngine (rather than AVAudioRecorder) gives a host-clock timestamp for every buffer,
/// which tells exactly when the first sample was captured and lets us fill interruptions
/// with silence so the file timeline never drifts from real time.
final class AudioRecorder {
    struct Result {
        var url: URL
        var format: WatchAudioFormat
        var sampleRate: Double
        var hardwareSampleRate: Double
        var startHostTime: Double
        var startWallTime: Date
        var duration: Double
        var silenceInserted: Double
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

    /// Input level in dBFS, delivered on the main queue about 10 times per second.
    var onLevel: ((Float) -> Void)?

    private let logger = Logger(subsystem: "WatchCam", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Guarded by `lock`: touched from the tap thread and from the main thread.
    private var file: AVAudioFile?
    private var url: URL?
    private var format: WatchAudioFormat = .aac
    private var hardwareSampleRate: Double = 0
    private var startHostTime: Double?
    private var startWallTime: Date?
    private var nextExpectedHostTime: Double?
    private var framesWritten: AVAudioFramePosition = 0
    private var silenceFrames: AVAudioFramePosition = 0
    private var lastLevelTime: Double = 0

    private var observers: [NSObjectProtocol] = []

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    /// Host time of the first captured sample, once known.
    var firstSampleHostTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return startHostTime
    }

    func start(url: URL, format requestedFormat: WatchAudioFormat) throws {
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

        let (file, actualFormat) = try Self.makeFile(url: url, format: requestedFormat, sampleRate: inputFormat.sampleRate)
        logger.info("Recording \(actualFormat.rawValue, privacy: .public) at \(inputFormat.sampleRate) Hz to \(url.lastPathComponent, privacy: .public)")

        lock.lock()
        self.file = file
        self.url = url
        self.format = actualFormat
        self.hardwareSampleRate = session.sampleRate
        startHostTime = nil
        startWallTime = nil
        nextExpectedHostTime = nil
        framesWritten = 0
        silenceFrames = 0
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
        self.file = nil
        let result: Result? = {
            guard let url, let file, let startHostTime, let startWallTime else { return nil }
            let rate = file.processingFormat.sampleRate
            return Result(
                url: url,
                format: format,
                sampleRate: rate,
                hardwareSampleRate: hardwareSampleRate,
                startHostTime: startHostTime,
                startWallTime: startWallTime,
                duration: Double(framesWritten) / rate,
                silenceInserted: Double(silenceFrames) / rate
            )
        }()
        lock.unlock()

        // Closing the file writes the final header and packet table.
        if #available(watchOS 11.0, *) {
            file?.close()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return result
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
            logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
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
        logger.warning("Inserted \(Double(frames) / file.processingFormat.sampleRate) s of silence after a gap")
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRecording,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.restartEngine()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.restartEngine()
        })
    }

    private func restartEngine() {
        guard !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            logger.info("Engine restarted after interruption")
        } catch {
            logger.error("Engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - File

    private static func makeFile(url: URL, format: WatchAudioFormat, sampleRate: Double) throws -> (AVAudioFile, WatchAudioFormat) {
        if format == .aac {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable,
                AVEncoderAudioQualityForVBRKey: AVAudioQuality.max.rawValue,
            ]
            if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                return (file, .aac)
            }
            // Some sample rates have no AAC encoder configuration: fall back to lossless.
            try? FileManager.default.removeItem(at: url)
        }
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
        return (file, .pcm)
    }
}
