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
