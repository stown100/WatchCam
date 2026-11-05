import Foundation

/// Maps the Digital Crown position to camera zoom, with "magnetic" steps.
///
/// Between steps, equal crown turns give equal zoom ratios (1× → 2× feels like 2× → 4×).
/// At each step there is a stretch of the dial where the zoom stays exactly on that step,
/// so it's easy to land on 2× or 3×, and getting past it takes a longer turn.
struct ZoomDial: Equatable {
    /// How much crown travel each step holds, in octaves of zoom: 0.5 is the turn that
    /// would otherwise change the zoom by about 41%. Larger = harder to get past.
    static let stepWidth = 0.5

    let range: ClosedRange<Double>
    let steps: [Double]

    init(range: ClosedRange<Double>, steps: [Double]) {
        self.range = range
        self.steps = steps.filter(range.contains).sorted()
    }

    /// Total crown travel.
    var length: Double {
        log2(range.upperBound / range.lowerBound) + Double(steps.count) * Self.stepWidth
    }

    func isStep(_ zoom: Double) -> Bool {
        steps.contains { abs($0 - zoom) < 0.001 }
    }

    /// The first step a turn runs into on its way between two dial positions, and the edge of
    /// the step's stretch it arrives at. A turn that starts inside a stretch doesn't count for it.
    func stepEntered(from start: Double, to end: Double) -> (step: Double, position: Double)? {
        if end > start {
            return stretches.first { start < $0.start && end >= $0.start }.map { ($0.step, $0.start) }
        }
        return stretches.last { start > $0.end && end <= $0.end }.map { ($0.step, $0.end) }
    }

    private var stretches: [(step: Double, start: Double, end: Double)] {
        var position = 0.0
        var lower = log2(range.lowerBound)
        return steps.map { step in
            position += log2(step) - lower
            lower = log2(step)
            defer { position += Self.stepWidth }
            return (step, position, position + Self.stepWidth)
        }
    }

    func zoom(atCrown position: Double) -> Double {
        // Positions are sums of logarithms: allow for rounding, so a stretch's edge still shows its step.
        let tolerance = 1e-9
        var remaining = max(position, 0)
        var lower = log2(range.lowerBound)
        for step in steps {
            let gap = log2(step) - lower
            if remaining < gap - tolerance { return pow(2, lower + remaining) }
            remaining = max(remaining - gap, 0)
            if remaining <= Self.stepWidth + tolerance { return step }
            remaining -= Self.stepWidth
            lower = log2(step)
        }
        return min(pow(2, lower + remaining), range.upperBound)
    }

    /// The crown position showing `zoom`: the middle of a step's stretch, if it's on a step.
    func crownPosition(forZoom zoom: Double) -> Double {
        let target = log2(min(max(zoom, range.lowerBound), range.upperBound))
        var position = 0.0
        var lower = log2(range.lowerBound)
        for step in steps {
            let stepLog = log2(step)
            // Zoom read back from the camera isn't exactly round.
            if abs(target - stepLog) < 0.01 { return position + stepLog - lower + Self.stepWidth / 2 }
            if target < stepLog { return position + target - lower }
            position += stepLog - lower + Self.stepWidth
            lower = stepLog
        }
        return position + target - lower
    }
}

/// Turns raw Digital Crown movement into a position on a `ZoomDial`, and makes the steps catch it.
///
/// A stretch on the dial alone is easy to fly through with a quick turn. So when a turn reaches
/// a step, the rest of it is dropped, and for a moment all rotation is ignored. A flick always
/// ends on the step; going further takes another turn, across the whole stretch.
struct MagneticCrown {
    /// Seconds a step ignores the crown after catching it. Longer = harder to get past.
    static let holdTime = 0.35

    private(set) var position = 0.0
    private var lastRaw = 0.0
    private var heldUntil = -Double.infinity

    /// - Parameters:
    ///   - raw: the crown's own value; only its changes matter.
    ///   - time: current time, in seconds.
    /// - Returns: the zoom to show.
    mutating func turn(to raw: Double, at time: Double, on dial: ZoomDial) -> Double {
        let delta = raw - lastRaw
        lastRaw = raw
        guard time >= heldUntil else { return dial.zoom(atCrown: position) }

        let end = min(max(position + delta, 0), dial.length)
        if let entered = dial.stepEntered(from: position, to: end) {
            position = entered.position
            heldUntil = time + Self.holdTime
        } else {
            position = end
        }
        return dial.zoom(atCrown: position)
    }

    /// Jumps to a position without any catching: the zoom was changed elsewhere.
    mutating func move(to position: Double) {
        self.position = position
        heldUntil = -Double.infinity
    }
}
