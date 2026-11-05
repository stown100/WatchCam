import AVFoundation
import Accelerate

/// Mono PCM samples cut from a file, positioned on that file's timeline.
public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Timeline position of `samples[0]`, in seconds.
    public var startTime: Double

    public var duration: Double { Double(samples.count) / sampleRate }
}

public enum SyncError: Error, LocalizedError {
    case noAudioTrack(URL)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack(let url): "No audio track in \(url.lastPathComponent)"
        case .readFailed(let message): "Audio read failed: \(message)"
        }
    }
}

/// Reads audio tracks through AVAssetReader.
///
/// Decoding goes through the same asset timeline that AVComposition uses later, so
/// encoder priming (AAC) and edit lists are handled identically for sync and for merging.
public enum AudioDecoder {
    /// Time range of the first audio track, in seconds.
    public static func audioTimeRange(of url: URL) async throws -> ClosedRange<Double> {
        let track = try await firstAudioTrack(of: AVURLAsset(url: url), url: url)
        let range = try await track.load(.timeRange)
        return range.start.seconds...range.end.seconds
    }

    /// Decodes the first audio track to mono Float32 at `sampleRate`.
    public static func decodeMono(
        url: URL,
        sampleRate: Double,
        start: Double = 0,
        duration: Double? = nil
    ) async throws -> DecodedAudio {
        var samples: [Float] = []
        var firstTime: Double?
        try await read(url: url, sampleRate: sampleRate, start: start, duration: duration) { time, chunk in
            if firstTime == nil { firstTime = time }
            samples.append(contentsOf: chunk)
        }

        // The reader may hand out a little pre-roll before the requested start: drop it.
        var startTime = firstTime ?? start
        if startTime < start {
            let drop = min(samples.count, Int(((start - startTime) * sampleRate).rounded()))
            samples.removeFirst(drop)
            startTime += Double(drop) / sampleRate
        }
        if let duration {
            let maxCount = Int((duration * sampleRate).rounded())
            if samples.count > maxCount { samples.removeLast(samples.count - maxCount) }
        }
        return DecodedAudio(samples: samples, sampleRate: sampleRate, startTime: startTime)
    }

    /// Streams the whole track and returns RMS per block, without keeping the samples.
    public static func envelope(url: URL, sampleRate: Double, blockDuration: Double) async throws -> [Float] {
        let blockSize = max(1, Int(sampleRate * blockDuration))
        var blocks: [Float] = []
        var pending: [Float] = []
        pending.reserveCapacity(blockSize * 2)

        try await read(url: url, sampleRate: sampleRate, start: 0, duration: nil) { _, chunk in
            pending.append(contentsOf: chunk)
            var index = 0
            while pending.count - index >= blockSize {
                var rms: Float = 0
                pending.withUnsafeBufferPointer { buffer in
                    vDSP_rmsqv(buffer.baseAddress! + index, 1, &rms, vDSP_Length(blockSize))
                }
                blocks.append(rms)
                index += blockSize
            }
            pending.removeFirst(index)
        }
        return blocks
    }

    // MARK: - Private

    private static func firstAudioTrack(of asset: AVURLAsset, url: URL) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SyncError.noAudioTrack(url)
        }
        return track
    }

    private static func read(
        url: URL,
        sampleRate: Double,
        start: Double,
        duration: Double?,
        consume: (Double, [Float]) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await firstAudioTrack(of: asset, url: url)

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        if start > 0 || duration != nil {
            let startTime = CMTime(seconds: max(0, start), preferredTimescale: 48_000)
            let length = duration.map { CMTime(seconds: $0, preferredTimescale: 48_000) } ?? .positiveInfinity
            reader.timeRange = CMTimeRange(start: startTime, duration: length)
        }

        guard reader.startReading() else {
            throw SyncError.readFailed(reader.error?.localizedDescription ?? "cannot start reading")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }

            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            consume(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, chunk)
        }

        if reader.status == .failed {
            throw SyncError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
    }
}
