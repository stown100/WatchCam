import Foundation

/// One NTP-style round trip between a client (watch) and a server (phone).
///
/// All values are seconds on each device's own monotonic host clock.
public struct RoundTrip: Sendable, Equatable, Codable {
    /// Client clock: request sent.
    public var t1: Double
    /// Server clock: request received.
    public var t2: Double
    /// Server clock: reply sent.
    public var t3: Double
    /// Client clock: reply received.
    public var t4: Double

    public init(t1: Double, t2: Double, t3: Double, t4: Double) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
    }

    /// Network round-trip delay, excluding the server's processing time.
    public var delay: Double { (t4 - t1) - (t3 - t2) }

    /// Estimated `serverClock - clientClock`. Error is bounded by `delay / 2`.
    public var offset: Double { ((t2 - t1) + (t3 - t4)) / 2 }
}

public struct ClockEstimate: Sendable, Equatable, Codable {
    /// `serverClock - clientClock`, in seconds.
    public var offset: Double
    /// Round-trip delay of the sample the estimate came from.
    public var delay: Double
    /// Number of valid samples considered.
    public var sampleCount: Int

    /// Worst-case error of `offset` (assuming symmetric bounds).
    public var uncertainty: Double { delay / 2 }
}

public enum ClockSync {
    /// Picks the sample with the smallest round trip, like NTP's clock filter:
    /// the shorter the trip, the less room for asymmetric delays to bias the offset.
    public static func estimate(_ samples: [RoundTrip]) -> ClockEstimate? {
        let valid = samples.filter { $0.delay >= 0 && $0.t4 >= $0.t1 && $0.t3 >= $0.t2 }
        guard let best = valid.min(by: { $0.delay < $1.delay }) else { return nil }
        return ClockEstimate(offset: best.offset, delay: best.delay, sampleCount: valid.count)
    }
}
