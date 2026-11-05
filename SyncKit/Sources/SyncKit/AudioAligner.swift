import Accelerate
import Foundation

/// Result of aligning one window of the reference against the target.
public struct WindowAlignment: Sendable, Equatable, Codable {
    /// Centre of the analysed reference window (reference timeline, seconds).
    public var referenceTime: Double
    /// `targetTime - referenceTime` at that point, in seconds.
    public var offset: Double
    /// How far the peak stands out from the correlation floor, in standard deviations.
    public var zScore: Double
    /// Main peak divided by the strongest peak outside its neighbourhood.
    public var peakRatio: Double
    public var isReliable: Bool

    public init(referenceTime: Double, offset: Double, zScore: Double, peakRatio: Double, isReliable: Bool) {
        self.referenceTime = referenceTime
        self.offset = offset
        self.zScore = zScore
        self.peakRatio = peakRatio
        self.isReliable = isReliable
    }

    /// 0...1 score for the UI, derived from the z-score.
    public var confidence: Double {
        max(0, min(1, 1 - exp(-(zScore - 6) / 8)))
    }
}

/// Finds the time shift between two recordings of the same sound.
public enum AudioAligner {
    public struct Parameters: Sendable {
        public var phatBeta: Float = 0.8
        public var minFrequency: Double = 100
        public var maxFrequency: Double = 3800
        /// Area around the main peak ignored when measuring the floor (early reflections live here).
        public var exclusionRadius: Double = 0.02
        public var minZScore: Double = 10
        public var minPeakRatio: Double = 1.3
        /// Each half of the window is aligned on its own; a real match gives the same answer twice,
        /// a coincidental peak almost never does.
        public var halfAgreementTolerance: Double = 0.003

        public init() {}
    }

    /// Aligns `reference` against `target`.
    ///
    /// - Parameters:
    ///   - referenceStart: timeline position of `reference[0]`, seconds.
    ///   - targetStart: timeline position of `target[0]`, seconds.
    ///   - searchRange: offsets (`targetTime - referenceTime`) to consider.
    /// - Returns: `nil` if the inputs don't overlap the search range at all.
    public static func align(
        reference: [Float], referenceStart: Double,
        target: [Float], targetStart: Double,
        sampleRate: Double,
        searchRange: ClosedRange<Double>,
        parameters: Parameters = Parameters()
    ) -> WindowAlignment? {
        guard let full = findPeak(
            reference: reference, referenceStart: referenceStart,
            target: target, targetStart: targetStart,
            sampleRate: sampleRate, searchRange: searchRange, parameters: parameters
        ) else { return nil }

        var isReliable = full.zScore >= parameters.minZScore && full.peakRatio >= parameters.minPeakRatio
        if isReliable {
            let half = reference.count / 2
            let halves = [
                (Array(reference[..<half]), referenceStart),
                (Array(reference[half...]), referenceStart + Double(half) / sampleRate),
            ]
            for (part, partStart) in halves {
                let peak = findPeak(
                    reference: part, referenceStart: partStart,
                    target: target, targetStart: targetStart,
                    sampleRate: sampleRate, searchRange: searchRange, parameters: parameters
                )
                guard let peak, abs(peak.offset - full.offset) <= parameters.halfAgreementTolerance else {
                    isReliable = false
                    break
                }
            }
        }

        let referenceDuration = Double(reference.count) / sampleRate
        return WindowAlignment(
            referenceTime: referenceStart + referenceDuration / 2,
            offset: full.offset,
            zScore: full.zScore,
            peakRatio: full.peakRatio,
            isReliable: isReliable
        )
    }

    private struct Peak {
        var offset: Double
        var zScore: Double
        var peakRatio: Double
    }

    private static func findPeak(
        reference: [Float], referenceStart: Double,
        target: [Float], targetStart: Double,
        sampleRate: Double,
        searchRange: ClosedRange<Double>,
        parameters: Parameters
    ) -> Peak? {
        guard reference.count > 16, target.count > 16 else { return nil }

        let options = FFTCorrelator.Options(
            phatBeta: parameters.phatBeta,
            minFrequency: parameters.minFrequency,
            maxFrequency: min(parameters.maxFrequency, sampleRate * 0.475),
            sampleRate: sampleRate
        )
        let correlation = FFTCorrelator.crossCorrelate(demeaned(reference), demeaned(target), options: options)
        let n = correlation.count
        guard n > 0 else { return nil }

        // Lag k (in samples) maps to offset = base + k / sampleRate.
        let base = targetStart - referenceStart
        let kMin = max(Int(((searchRange.lowerBound - base) * sampleRate).rounded(.up)), -(reference.count - 1))
        let kMax = min(Int(((searchRange.upperBound - base) * sampleRate).rounded(.down)), target.count - 1)
        guard kMax - kMin >= 4 else { return nil }

        let count = kMax - kMin + 1
        var values = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let k = kMin + i
            values[i] = abs(correlation[k >= 0 ? k : n + k])
        }

        var peak: Float = 0
        var peakIndexU: vDSP_Length = 0
        vDSP_maxvi(values, 1, &peak, &peakIndexU, vDSP_Length(count))
        let peakIndex = Int(peakIndexU)

        // Sub-sample refinement: fit a parabola through the peak and its neighbours.
        var fraction = 0.0
        if peakIndex > 0, peakIndex < count - 1 {
            let y0 = Double(values[peakIndex - 1])
            let y1 = Double(values[peakIndex])
            let y2 = Double(values[peakIndex + 1])
            let denominator = y0 - 2 * y1 + y2
            if denominator < 0 {
                fraction = max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
            }
        }
        let lag = Double(kMin + peakIndex) + fraction
        let offset = base + lag / sampleRate

        // Confidence: compare the peak with everything outside its neighbourhood.
        let exclusion = max(1, Int(parameters.exclusionRadius * sampleRate))
        var sum = 0.0
        var sumSquares = 0.0
        var floorCount = 0
        var secondPeak: Float = 0
        for i in 0..<count where abs(i - peakIndex) > exclusion {
            let value = Double(values[i])
            sum += value
            sumSquares += value * value
            floorCount += 1
            secondPeak = max(secondPeak, values[i])
        }

        var zScore = 0.0
        var peakRatio = 1.0
        if floorCount >= 16 {
            let mean = sum / Double(floorCount)
            let deviation = max(sumSquares / Double(floorCount) - mean * mean, 1e-30).squareRoot()
            zScore = (Double(peak) - mean) / deviation
            peakRatio = secondPeak > 0 ? min(1000, Double(peak / secondPeak)) : 1000
        }

        return Peak(offset: offset, zScore: zScore, peakRatio: peakRatio)
    }

    static func demeaned(_ signal: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(signal.count))
        var negativeMean = -mean
        var result = [Float](repeating: 0, count: signal.count)
        vDSP_vsadd(signal, 1, &negativeMean, &result, 1, vDSP_Length(signal.count))
        return result
    }
}
