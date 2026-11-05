import Foundation

/// Which parts of a video have real sound from an external recording.
///
/// An external recording can be incomplete: it may have stopped early or have holes in it.
/// The video must not get shorter because of that, so these parts are found and filled.
public enum AudioCoverage {
    /// Shorter holes stay silent: they're too small to be worth a change of microphone.
    public static let shortestFilledGap = 0.25
    /// Up to this much at either end of a take is normal: the clip is simply trimmed by it.
    public static let shortestFilledEdge = 1.0
    /// With filling under way anyway, smaller edges don't count.
    private static let shortestEdgeWhenFilling = 0.02

    /// The longest stretch of a file that holds real sound, in seconds of the file.
    public static func longestSoundSpan(audioDuration: Double, gaps: [ClosedRange<Double>]) -> ClosedRange<Double> {
        var best = 0.0...0.0
        var start = 0.0
        func consider(_ end: Double) {
            if end - start > best.upperBound - best.lowerBound { best = start...end }
        }
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            consider(min(gap.lowerBound, audioDuration))
            start = max(start, gap.upperBound)
        }
        consider(audioDuration)
        return best
    }

    /// The parts of a video left without sound, in video seconds. Empty if nothing needs filling.
    ///
    /// - Parameters:
    ///   - gaps: holes in the file, in seconds of the file.
    ///   - offset: `audioTime - videoTime`.
    public static func missing(
        videoDuration: Double,
        audioDuration: Double,
        gaps: [ClosedRange<Double>],
        offset: Double
    ) -> [ClosedRange<Double>] {
        guard videoDuration > 0 else { return [] }
        let soundStart = min(max(-offset, 0), videoDuration)
        let soundEnd = min(max(audioDuration - offset, 0), videoDuration)

        let leading = soundStart
        let trailing = videoDuration - soundEnd
        let holes: [ClosedRange<Double>] = gaps.compactMap { gap in
            let start = max(gap.lowerBound - offset, 0)
            let end = min(gap.upperBound - offset, videoDuration)
            return end - start >= shortestFilledGap ? start...end : nil
        }
        guard leading >= shortestFilledEdge || trailing >= shortestFilledEdge || !holes.isEmpty else { return [] }

        var ranges = holes
        if leading >= shortestEdgeWhenFilling { ranges.append(0...soundStart) }
        if trailing >= shortestEdgeWhenFilling { ranges.append(soundEnd...videoDuration) }

        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
