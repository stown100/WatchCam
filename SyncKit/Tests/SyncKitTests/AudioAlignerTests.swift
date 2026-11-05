import Foundation
import Testing
@testable import SyncKit

/// Unit tests for the correlation core, working directly on 8 kHz sample arrays.
///
/// Convention: the "world" signal is what was said. The reference (iPhone) starts
/// recording at world time `referenceStart`, the target (watch) at `targetStart`.
/// Then `targetTime = referenceTime + (referenceStart - targetStart)`.
struct AudioAlignerTests {
    let rate = 8_000.0
    let world = Synth.speechLike(duration: 40, sampleRate: 8_000, seed: 42)

    private func align(
        reference: [Float], target: [Float], expected: Double, radius: Double = 2
    ) -> WindowAlignment {
        AudioAligner.align(
            reference: reference, referenceStart: 0,
            target: target, targetStart: 0,
            sampleRate: rate,
            searchRange: (expected - radius)...(expected + radius)
        )!
    }

    @Test func findsExactShift() {
        let reference = Synth.slice(world, sampleRate: rate, start: 3.0, duration: 20)
        let target = Synth.slice(world, sampleRate: rate, start: 1.75, duration: 26)

        let result = align(reference: reference, target: target, expected: 1.25)

        #expect(abs(result.offset - 1.25) < 0.000_5)
        #expect(result.isReliable)
    }

    @Test func findsFractionalShift() {
        // 1.23456 s is not a whole number of samples at 8 kHz.
        let reference = Synth.slice(world, sampleRate: rate, start: 3.0, duration: 20)
        let target = Synth.slice(world, sampleRate: rate, start: 3.0 - 1.234_56, duration: 26)

        let result = align(reference: reference, target: target, expected: 1.2)

        #expect(abs(result.offset - 1.234_56) < 0.000_5)
        #expect(result.isReliable)
    }

    @Test func toleratesCoarseErrorInsideSearchRadius() {
        let reference = Synth.slice(world, sampleRate: rate, start: 3.0, duration: 20)
        let target = Synth.slice(world, sampleRate: rate, start: 0.5, duration: 26)

        // True offset is 2.5 s, the clocks said 0.8 s.
        let result = align(reference: reference, target: target, expected: 0.8, radius: 2)

        #expect(abs(result.offset - 2.5) < 0.000_5)
        #expect(result.isReliable)
    }

    /// The realistic case: iPhone several metres away (quiet, reverberant, noisy),
    /// watch close to the mouth (loud and dry, but with its own noise).
    @Test(arguments: [10.0, 0.0, -5.0])
    func farReferenceWithNoiseAndReverb(snrDB: Double) {
        let room = Synth.roomImpulse(sampleRate: rate, rt60: 0.45, directToReverbDB: -3, seed: 7)
        let farWorld = Synth.convolve(world, with: room)

        let cleanReference = Synth.scaled(Synth.slice(farWorld, sampleRate: rate, start: 4.0, duration: 20), by: 0.05)
        let signalPower = cleanReference.reduce(0) { $0 + $1 * $1 } / Float(cleanReference.count)
        let noiseAmplitude = (3 * signalPower / Float(pow(10, snrDB / 10))).squareRoot()
        let reference = Synth.added(cleanReference,
                                    Synth.whiteNoise(count: cleanReference.count, amplitude: noiseAmplitude, seed: 11))

        let cleanTarget = Synth.slice(world, sampleRate: rate, start: 2.2, duration: 26)
        let target = Synth.added(cleanTarget, Synth.whiteNoise(count: cleanTarget.count, amplitude: 0.01, seed: 12))

        let result = align(reference: reference, target: target, expected: 1.8 + 0.6)

        #expect(abs(result.offset - 1.8) < 0.002, "SNR \(snrDB) dB: offset \(result.offset), z \(result.zScore)")
        #expect(result.isReliable, "SNR \(snrDB) dB: z \(result.zScore), ratio \(result.peakRatio)")
    }

    @Test func rejectsUnrelatedRecordings() {
        let other = Synth.speechLike(duration: 40, sampleRate: rate, seed: 99)
        let reference = Synth.slice(world, sampleRate: rate, start: 3.0, duration: 20)
        let target = Synth.slice(other, sampleRate: rate, start: 1.0, duration: 26)

        let result = align(reference: reference, target: target, expected: 1.5)

        #expect(!result.isReliable, "z \(result.zScore), ratio \(result.peakRatio)")
    }

    @Test func rejectsPureNoise() {
        let reference = Synth.whiteNoise(count: Int(20 * rate), amplitude: 0.1, seed: 5)
        let target = Synth.slice(world, sampleRate: rate, start: 1.0, duration: 26)

        let result = align(reference: reference, target: target, expected: 1.5)

        #expect(!result.isReliable, "z \(result.zScore), ratio \(result.peakRatio)")
    }
}

struct ClockSyncTests {
    @Test func picksMinimumRoundTrip() {
        // True offset: phone = watch + 1000.25 s. Network delays are asymmetric and vary.
        let trueOffset = 1_000.25
        let trips: [(Double, Double)] = [(0.080, 0.020), (0.015, 0.012), (0.200, 0.030), (0.040, 0.090)]
        var samples: [RoundTrip] = []
        var watchTime = 50.0
        for (up, down) in trips {
            let t1 = watchTime
            let t2 = t1 + up + trueOffset
            let t3 = t2 + 0.001
            let t4 = t3 - trueOffset + down
            samples.append(RoundTrip(t1: t1, t2: t2, t3: t3, t4: t4))
            watchTime += 1
        }

        let estimate = ClockSync.estimate(samples)!

        #expect(abs(estimate.delay - 0.027) < 1e-9)
        #expect(abs(estimate.offset - trueOffset) <= estimate.uncertainty)
        #expect(abs(estimate.offset - trueOffset) < 0.002)
        #expect(estimate.sampleCount == 4)
    }

    @Test func ignoresBrokenSamples() {
        let broken = RoundTrip(t1: 10, t2: 5, t3: 4, t4: 9)
        #expect(ClockSync.estimate([broken]) == nil)
    }
}

struct MergePlannerTests {
    @Test func watchStartedEarlierAndStoppedLater() {
        let plan = MergePlanner.plan(video: 0...60, audio: 0...65, offset: 1.5)!
        #expect(plan == MergePlan(videoStart: 0, audioStart: 1.5, duration: 60))
    }

    @Test func watchStoppedFirstTrimsTheEnd() {
        let plan = MergePlanner.plan(video: 0...60, audio: 0...61, offset: 1.5)!
        #expect(plan.videoStart == 0)
        #expect(abs(plan.duration - 59.5) < 1e-9)
    }

    @Test func watchStartedLateTrimsTheBeginning() {
        let plan = MergePlanner.plan(video: 0...60, audio: 0...70, offset: -2)!
        #expect(plan == MergePlan(videoStart: 2, audioStart: 0, duration: 58))
    }

    @Test func noOverlap() {
        #expect(MergePlanner.plan(video: 0...10, audio: 0...5, offset: 8) == nil)
    }
}
