import AVFoundation

/// File-level audio operations used after sync: drift correction and aligned export.
public enum AudioFileTools {
    public enum ToolError: Error, LocalizedError {
        case unsupportedFormat
        case conversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Unsupported audio format"
            case .conversionFailed(let message): "Audio conversion failed: \(message)"
            }
        }
    }

    /// Time-scales a recording to cancel clock drift: output time `u` holds input time `ratio · u`.
    ///
    /// Done by re-labelling the input as if it ran at `rate · ratio` and converting it back to
    /// `rate` with the highest-quality resampler. Output is 24-bit PCM at the input's sample rate.
    public static func timeScale(input: URL, output: URL, ratio: Double) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ToolError.unsupportedFormat }

        let rate = format.sampleRate
        let channels = format.channelCount
        guard let relabelled = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate * ratio,
                                             channels: channels, interleaved: false) else { throw ToolError.unsupportedFormat }

        try? FileManager.default.removeItem(at: output)
        let destination = try AVAudioFile(forWriting: output, settings: pcmSettings(rate: rate, channels: channels, bitDepth: 24),
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: relabelled, to: destination.processingFormat) else {
            throw ToolError.unsupportedFormat
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let chunk: AVAudioFrameCount = 8_192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ToolError.unsupportedFormat }
        let feeder = Feeder()

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: destination.processingFormat, frameCapacity: chunk) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { requested, inputStatus in
                if feeder.finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try source.read(into: readBuffer, frameCount: min(requested, chunk))
                } catch {
                    feeder.finished = true
                }
                guard !feeder.finished, readBuffer.frameLength > 0,
                      let relabelledBuffer = AVAudioPCMBuffer(pcmFormat: relabelled, frameCapacity: readBuffer.frameLength) else {
                    feeder.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // Same samples, different declared rate.
                relabelledBuffer.frameLength = readBuffer.frameLength
                for channel in 0..<Int(channels) {
                    relabelledBuffer.floatChannelData![channel].update(from: readBuffer.floatChannelData![channel],
                                                                      count: Int(readBuffer.frameLength))
                }
                inputStatus.pointee = .haveData
                return relabelledBuffer
            }
            if outBuffer.frameLength > 0 { try destination.write(from: outBuffer) }
            if status == .error { throw ToolError.conversionFailed(conversionError?.localizedDescription ?? "unknown") }
            if status == .endOfStream { break }
        }
    }

    /// Writes a WAV that lines up with a video from its very first frame: sample 0 of the WAV
    /// plays at video time 0. Missing audio at either end is filled with silence.
    ///
    /// - Parameter offset: `audioTime - videoTime` for `input`.
    public static func writeAligned(input: URL, offset: Double, videoDuration: Double, output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let rate = format.sampleRate
        let channels = format.channelCount

        try? FileManager.default.removeItem(at: output)
        let destination = try AVAudioFile(forWriting: output, settings: pcmSettings(rate: rate, channels: channels, bitDepth: 24),
                                          commonFormat: .pcmFormatFloat32, interleaved: false)

        let totalFrames = AVAudioFramePosition((videoDuration * rate).rounded())
        var written: AVAudioFramePosition = 0
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ToolError.unsupportedFormat }

        func writeSilence(_ frames: AVAudioFramePosition) throws {
            var remaining = frames
            while remaining > 0 {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                buffer.frameLength = count
                for channel in 0..<Int(channels) {
                    buffer.floatChannelData![channel].update(repeating: 0, count: Int(count))
                }
                try destination.write(from: buffer)
                remaining -= AVAudioFramePosition(count)
            }
        }

        // Watch started after the video: silence first.
        let startFrame = AVAudioFramePosition((offset * rate).rounded())
        if startFrame < 0 {
            let lead = min(-startFrame, totalFrames)
            try writeSilence(lead)
            written += lead
        } else {
            source.framePosition = min(startFrame, source.length)
        }

        while written < totalFrames, source.framePosition < source.length {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - written))
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try destination.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
        // Watch stopped before the video: silence at the end.
        if written < totalFrames { try writeSilence(totalFrames - written) }
    }

    /// Builds one continuous sound track for a whole video from an incomplete recording: its own
    /// sound where it has it, the sound from the video elsewhere, brought to a similar level.
    /// Sample 0 of the output plays at video time 0.
    ///
    /// - Parameters:
    ///   - offset: `audioTime - videoTime` for `watch`.
    ///   - missing: parts of the video to take from the video's own sound, in video seconds.
    public static func fillMissing(
        watch: URL,
        offset: Double,
        missing: [ClosedRange<Double>],
        video: URL,
        videoDuration: Double,
        output: URL
    ) async throws {
        let source = try AVAudioFile(forReading: watch)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, format.channelCount == 1 else {
            throw ToolError.unsupportedFormat
        }
        let rate = format.sampleRate
        let gain = try await matchingGain(watch: watch, offset: offset, missing: missing, video: video, videoDuration: videoDuration)

        try? FileManager.default.removeItem(at: output)
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable,
            AVEncoderAudioQualityForVBRKey: AVAudioQuality.max.rawValue,
        ]
        let destination: AVAudioFile
        if let file = try? AVAudioFile(forWriting: output, settings: aac, commonFormat: .pcmFormatFloat32, interleaved: false) {
            destination = file
        } else {
            destination = try AVAudioFile(forWriting: output, settings: pcmSettings(rate: rate, channels: 1, bitDepth: 24),
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        func frame(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw ToolError.unsupportedFormat
        }

        /// Writes what's in `buffer`, a piece's frames from `index` on, softening the piece's joins.
        func writeBuffer(index: Int, count: Int, fadeIn: Bool, fadeOut: Bool) throws {
            let fade = Float(rate * 0.02)
            let samples = buffer.floatChannelData![0]
            for position in 0..<Int(buffer.frameLength) {
                let frame = index + position
                if fadeIn, Float(frame) < fade { samples[position] *= Float(frame) / fade }
                if fadeOut, Float(count - 1 - frame) < fade { samples[position] *= Float(count - 1 - frame) / fade }
            }
            try destination.write(from: buffer)
        }

        func writeWatchPiece(_ range: ClosedRange<Double>) throws {
            let count = frame(range.upperBound) - frame(range.lowerBound)
            let fadeIn = range.lowerBound > 0, fadeOut = range.upperBound < videoDuration
            var position = AVAudioFramePosition(((range.lowerBound + offset) * rate).rounded())
            var done = 0
            while done < count {
                let wanted = min(chunk, count - done)
                if position >= 0, position < source.length {
                    source.framePosition = position
                    let available = min(AVAudioFramePosition(wanted), source.length - position)
                    try source.read(into: buffer, frameCount: AVAudioFrameCount(available))
                }
                if position < 0 || position >= source.length || buffer.frameLength == 0 {
                    // Outside the file: silence, up to where the file begins.
                    let silent = position < 0 ? min(AVAudioFramePosition(wanted), -position) : AVAudioFramePosition(wanted)
                    buffer.frameLength = AVAudioFrameCount(silent)
                    buffer.floatChannelData![0].update(repeating: 0, count: Int(silent))
                }
                try writeBuffer(index: done, count: count, fadeIn: fadeIn, fadeOut: fadeOut)
                done += Int(buffer.frameLength)
                position += AVAudioFramePosition(buffer.frameLength)
            }
        }

        func writeVideoPiece(_ range: ClosedRange<Double>, decoded: DecodedAudio) throws {
            let count = frame(range.upperBound) - frame(range.lowerBound)
            let fadeIn = range.lowerBound > 0, fadeOut = range.upperBound < videoDuration
            let lead = max(0, frame(decoded.startTime - range.lowerBound))
            var done = 0
            while done < count {
                let wanted = min(chunk, count - done)
                let samples = buffer.floatChannelData![0]
                for position in 0..<wanted {
                    let index = done + position - lead
                    let sample = index >= 0 && index < decoded.samples.count ? decoded.samples[index] * gain : 0
                    samples[position] = max(-1, min(1, sample))
                }
                buffer.frameLength = AVAudioFrameCount(wanted)
                try writeBuffer(index: done, count: count, fadeIn: fadeIn, fadeOut: fadeOut)
                done += wanted
            }
        }

        var position = 0.0
        for range in missing.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > position { try writeWatchPiece(position...range.lowerBound) }
            let decoded = try await AudioDecoder.decodeMono(
                url: video, sampleRate: rate, start: range.lowerBound, duration: range.upperBound - range.lowerBound)
            try writeVideoPiece(range, decoded: decoded)
            position = range.upperBound
        }
        if position < videoDuration { try writeWatchPiece(position...videoDuration) }

        // Closing the file makes compressed audio readable. Before these versions that happens on release.
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            destination.close()
        }
    }

    /// How much to raise the video's sound to match the recording: the iPhone is usually much
    /// farther from the speaker than the watch. Measured where both have sound.
    private static func matchingGain(
        watch: URL,
        offset: Double,
        missing: [ClosedRange<Double>],
        video: URL,
        videoDuration: Double
    ) async throws -> Float {
        // The longest stretch of the video that the recording does cover.
        var longest = 0.0...0.0
        var start = 0.0
        for range in missing.sorted(by: { $0.lowerBound < $1.lowerBound }) + [videoDuration...videoDuration] {
            if range.lowerBound - start > longest.upperBound - longest.lowerBound { longest = start...range.lowerBound }
            start = range.upperBound
        }
        let length = min(longest.upperBound - longest.lowerBound, 30)
        guard length >= 1 else { return 1 }
        let middle = (longest.lowerBound + longest.upperBound) / 2

        let rate = 8_000.0
        let fromVideo = try await AudioDecoder.decodeMono(url: video, sampleRate: rate, start: middle - length / 2, duration: length)
        let fromWatch = try await AudioDecoder.decodeMono(url: watch, sampleRate: rate, start: middle - length / 2 + offset, duration: length)
        let videoLevel = rootMeanSquare(fromVideo.samples), watchLevel = rootMeanSquare(fromWatch.samples)
        guard videoLevel > 1e-5, watchLevel > 1e-5 else { return 1 }
        return max(0.25, min(8, watchLevel / videoLevel))
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    private static func pcmSettings(rate: Double, channels: AVAudioChannelCount, bitDepth: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Mutable state for the converter's input callback.
    private final class Feeder: @unchecked Sendable {
        var finished = false
    }
}
