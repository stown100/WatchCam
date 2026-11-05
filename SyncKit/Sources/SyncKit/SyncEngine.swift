import Foundation

/// Mapping between the reference timeline (iPhone video) and the target timeline (watch audio):
/// `targetTime = offset + ratio * referenceTime`.
public struct SyncResult: Sendable, Equatable, Codable {
    public enum Method: String, Sendable, Codable {
        /// Fine alignment by cross-correlation succeeded.
        case crossCorrelation
        /// Only the clock-based estimate was available ("approximate sync").
        case coarse
    }

    public var method: Method
    /// Target time that lines up with reference time 0, in seconds.
    public var offset: Double
    /// Target seconds per reference second. 1 means no clock drift.
    public var ratio: Double
    /// Confidence of the best window, 0...1 (0 for coarse).
    public var confidence: Double
    public var windows: [WindowAlignment]

    public init(method: Method, offset: Double, ratio: Double, confidence: Double, windows: [WindowAlignment]) {
        self.method = method
        self.offset = offset
        self.ratio = ratio
        self.confidence = confidence
        self.windows = windows
    }

    public var isApproximate: Bool { method == .coarse }
    public var driftPPM: Double { (ratio - 1) * 1_000_000 }

    /// `targetTime - referenceTime` at a given reference time.
    public func offset(at referenceTime: Double) -> Double {
        offset + (ratio - 1) * referenceTime
    }
}

public struct SyncConfiguration: Sendable {
    /// Both tracks are downmixed and resampled to this rate before correlating.
    public var analysisSampleRate: Double = 8_000
    /// Search ± this many seconds around the coarse estimate.
    public var searchRadius: Double = 2
    /// Length of each analysed reference window.
    public var windowDuration: Double = 20
    /// Up to this many windows spread over the recording (start/middle/end), used for drift.
    public var maxWindows: Int = 3
    /// Drift estimates above this are treated as errors.
    public var maxDriftPPM: Double = 500
    /// Minimum distance between windows before a drift estimate is trusted.
    public var minDriftSpan: Double = 60
    /// Maximum residual of a window against the fitted line.
    public var maxResidual: Double = 0.005
    public var aligner = AudioAligner.Parameters()

    public init() {}
}

/// Synchronizes a target recording (watch audio) to a reference (iPhone video's own audio).
public enum SyncEngine {
    /// - Parameter coarseOffset: clock-based estimate of `targetTime - referenceTime`, if known.
    public static func synchronize(
        reference: URL,
        target: URL,
        coarseOffset: Double?,
        configuration: SyncConfiguration = SyncConfiguration()
    ) async throws -> SyncResult {
        let rate = configuration.analysisSampleRate
        let coarse = coarseOffset ?? 0
        let radius = coarseOffset == nil ? max(configuration.searchRadius, 10) : configuration.searchRadius
        let fallback = SyncResult(method: .coarse, offset: coarse, ratio: 1, confidence: 0, windows: [])

        let referenceRange = try await AudioDecoder.audioTimeRange(of: reference)
        let targetRange = try await AudioDecoder.audioTimeRange(of: target)

        // Part of the reference that the (coarsely shifted) target covers.
        let overlapStart = max(referenceRange.lowerBound, targetRange.lowerBound - coarse)
        let overlapEnd = min(referenceRange.upperBound, targetRange.upperBound - coarse)
        guard overlapEnd - overlapStart >= 2 else { return fallback }

        let windowLength = min(configuration.windowDuration, overlapEnd - overlapStart)
        let blockDuration = 0.1
        let envelope = try await AudioDecoder.envelope(url: reference, sampleRate: rate, blockDuration: blockDuration)
        let windowStarts = WindowPicker.pick(
            envelope: envelope,
            blockDuration: blockDuration,
            timelineStart: referenceRange.lowerBound,
            range: overlapStart...overlapEnd,
            windowLength: windowLength,
            maxWindows: configuration.maxWindows
        )

        var results: [WindowAlignment] = []
        var anchor: WindowAlignment?
        for start in windowStarts {
            let center = start + windowLength / 2
            let expected: Double
            let searchRadius: Double
            if let anchor {
                // Once one window is solid, the others only need room for drift.
                expected = anchor.offset
                searchRadius = 0.1 + configuration.maxDriftPPM * 1e-6 * abs(center - anchor.referenceTime)
            } else {
                expected = coarse
                searchRadius = radius
            }

            let referenceAudio = try await AudioDecoder.decodeMono(
                url: reference, sampleRate: rate, start: start, duration: windowLength)
            let targetStart = max(targetRange.lowerBound, start + expected - searchRadius)
            let targetAudio = try await AudioDecoder.decodeMono(
                url: target, sampleRate: rate, start: targetStart, duration: windowLength + 2 * searchRadius)

            guard let alignment = AudioAligner.align(
                reference: referenceAudio.samples, referenceStart: referenceAudio.startTime,
                target: targetAudio.samples, targetStart: targetAudio.startTime,
                sampleRate: rate,
                searchRange: (expected - searchRadius)...(expected + searchRadius),
                parameters: configuration.aligner
            ) else { continue }

            results.append(alignment)
            if anchor == nil, alignment.isReliable { anchor = alignment }
        }

        results.sort { $0.referenceTime < $1.referenceTime }
        let reliable = results.filter(\.isReliable)
        guard !reliable.isEmpty else {
            return SyncResult(method: .coarse, offset: coarse, ratio: 1, confidence: 0, windows: results)
        }

        let line = fitTimeline(reliable, configuration: configuration)
        return SyncResult(
            method: .crossCorrelation,
            offset: line.offset,
            ratio: line.ratio,
            confidence: reliable.map(\.confidence).max() ?? 0,
            windows: results
        )
    }

    /// Fits `offset(t) = a + b·t` through reliable windows, rejecting outliers.
    static func fitTimeline(_ points: [WindowAlignment], configuration: SyncConfiguration) -> (offset: Double, ratio: Double) {
        var points = points
        while points.count >= 2 {
            let times = points.map(\.referenceTime)
            guard (times.max()! - times.min()!) >= configuration.minDriftSpan else { break }

            let meanTime = times.reduce(0, +) / Double(points.count)
            let meanOffset = points.map(\.offset).reduce(0, +) / Double(points.count)
            var sxx = 0.0
            var sxy = 0.0
            for point in points {
                sxx += (point.referenceTime - meanTime) * (point.referenceTime - meanTime)
                sxy += (point.referenceTime - meanTime) * (point.offset - meanOffset)
            }
            let slope = sxy / sxx
            let intercept = meanOffset - slope * meanTime
            let residuals = points.map { abs($0.offset - (intercept + slope * $0.referenceTime)) }

            if abs(slope) * 1_000_000 <= configuration.maxDriftPPM, residuals.max()! <= configuration.maxResidual {
                return (intercept, 1 + slope)
            }

            // Drop the most suspicious window and try again.
            if points.count > 2, let worst = residuals.indices.max(by: { residuals[$0] < residuals[$1] }) {
                points.remove(at: worst)
            } else if let weakest = points.indices.min(by: { points[$0].zScore < points[$1].zScore }) {
                points.remove(at: weakest)
            }
        }

        // Not enough spread to measure drift: constant offset from the strongest window.
        let best = points.max(by: { $0.zScore < $1.zScore })!
        return (best.offset, 1)
    }
}

/// Chooses where to analyse: the most "eventful" stretches of the reference.
enum WindowPicker {
    static func pick(
        envelope: [Float],
        blockDuration: Double,
        timelineStart: Double,
        range: ClosedRange<Double>,
        windowLength: Double,
        maxWindows: Int
    ) -> [Double] {
        let span = range.upperBound - range.lowerBound
        let regionCount = span >= windowLength * 2.5 ? max(1, maxWindows) : 1
        let regionLength = span / Double(regionCount)

        var starts: [(start: Double, score: Double)] = []
        for region in 0..<regionCount {
            let regionStart = range.lowerBound + Double(region) * regionLength
            let latestStart = max(regionStart, regionStart + regionLength - windowLength)
            var best = (start: regionStart, score: -Double.infinity)
            var candidate = regionStart
            while candidate <= latestStart + 1e-9 {
                let score = activity(envelope, from: candidate, length: windowLength,
                                     blockDuration: blockDuration, timelineStart: timelineStart)
                if score > best.score { best = (candidate, score) }
                candidate += 1
            }
            // Keep the window inside the overall range.
            best.start = min(max(best.start, range.lowerBound), range.upperBound - windowLength)
            starts.append(best)
        }
        // Strongest first: the first reliable window becomes the anchor for the others.
        return starts.sorted { $0.score > $1.score }.map(\.start)
    }

    /// Spread of loudness in dB: speech and transients score high, silence and steady hum score low.
    static func activity(_ envelope: [Float], from start: Double, length: Double,
                         blockDuration: Double, timelineStart: Double) -> Double {
        let first = max(0, Int((start - timelineStart) / blockDuration))
        let last = min(envelope.count, Int((start - timelineStart + length) / blockDuration))
        guard last - first >= 2 else { return 0 }
        let levels = envelope[first..<last].map { 20 * log10(Double($0) + 1e-6) }
        let mean = levels.reduce(0, +) / Double(levels.count)
        let variance = levels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(levels.count)
        return variance.squareRoot()
    }
}
