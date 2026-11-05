import AVFoundation
import Foundation
import Testing
@testable import SyncKit

/// End-to-end tests on real audio files, going through AVAssetReader like the app does.
struct SyncEngineTests {
    /// Watch audio as AAC at 48 kHz (the default watch format), iPhone reference as PCM.
    /// Checks that AAC encoder priming doesn't shift the result.
    @Test func aacTargetWithCoarseError() async throws {
        let rate = 48_000.0
        let world = Synth.speechLike(duration: 45, sampleRate: rate, seed: 3)

        // Video started 1.5 s after the watch; the clock estimate is 0.7 s off.
        let reference = Synth.scaled(Synth.slice(world, sampleRate: rate, start: 2.0, duration: 30), by: 0.1)
        let target = Synth.slice(world, sampleRate: rate, start: 0.5, duration: 40)

        let referenceURL = TestAudioFile.temporaryURL("reference.caf")
        let targetURL = TestAudioFile.temporaryURL("target.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .aac, to: targetURL)

        let result = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 1.5 + 0.7)

        #expect(result.method == .crossCorrelation)
        #expect(abs(result.offset - 1.5) < 0.002, "offset \(result.offset)")
        #expect(result.ratio == 1)
    }

    /// Watch microphone at 16 kHz vs iPhone at 48 kHz: resampling must not add a delay.
    @Test func differentSampleRates() async throws {
        let world = Synth.speechLike(duration: 45, sampleRate: 16_000, seed: 8)
        let reference16 = Synth.slice(world, sampleRate: 16_000, start: 3.0, duration: 30)
        // Upsample the reference to 48 kHz by interpolation (keeps timing exact).
        let reference = (0..<Int(30 * 48_000.0)).map { Synth.sample(reference16, at: Double($0) / 3) }
        let target = Synth.slice(world, sampleRate: 16_000, start: 1.0, duration: 40)

        let referenceURL = TestAudioFile.temporaryURL("reference48.caf")
        let targetURL = TestAudioFile.temporaryURL("target16.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: 48_000, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: 16_000, encoding: .pcm16, to: targetURL)

        let result = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 2.3)

        #expect(result.method == .crossCorrelation)
        #expect(abs(result.offset - 2.0) < 0.002, "offset \(result.offset)")
    }

    /// Long take where the watch clock runs fast: the engine must see the drift.
    /// 40 ppm is a realistic crystal mismatch; 200 ppm is a stress case where the signal
    /// smears by 4 ms inside each 20 s window, so tolerances are looser (still far below 10 ms).
    @Test(arguments: [(40.0, 0.001, 5.0), (200.0, 0.004, 20.0)])
    func measuresClockDrift(ppm: Double, offsetTolerance: Double, driftTolerance: Double) async throws {
        let rate = 16_000.0
        let duration = 200.0
        let world = Synth.speechLike(duration: duration + 10, sampleRate: rate, seed: 21)

        let referenceStart = 2.0
        let trueOffset = 1.5
        let trueRatio = 1 + ppm / 1_000_000

        let reference = Synth.slice(world, sampleRate: rate, start: referenceStart, duration: duration)
        // target(u) = world((u - offset) / ratio + referenceStart)
        let targetCount = Int((duration + 3) * rate)
        let target = (0..<targetCount).map { index -> Float in
            let u = Double(index) / rate
            return Synth.sample(world, at: ((u - trueOffset) / trueRatio + referenceStart) * rate)
        }

        let referenceURL = TestAudioFile.temporaryURL("reference-long.caf")
        let targetURL = TestAudioFile.temporaryURL("target-long.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .pcm16, to: targetURL)

        let result = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 1.2)

        #expect(result.method == .crossCorrelation)
        #expect(result.windows.filter(\.isReliable).count >= 2)
        #expect(abs(result.offset - trueOffset) < offsetTolerance, "offset \(result.offset)")
        #expect(abs(result.driftPPM - ppm) < driftTolerance, "drift \(result.driftPPM) ppm")
        // At the end of the take the predicted offset must still be close.
        let endOffset = trueOffset + (trueRatio - 1) * duration
        #expect(abs(result.offset(at: duration) - endOffset) < offsetTolerance,
                "end offset \(result.offset(at: duration)) vs \(endOffset)")
    }

    /// The iPhone heard nothing useful: fall back to the clock estimate and say so.
    @Test func fallsBackToCoarseWhenReferenceIsSilent() async throws {
        let rate = 16_000.0
        let reference = Synth.whiteNoise(count: Int(30 * rate), amplitude: 0.001, seed: 1)
        let target = Synth.speechLike(duration: 35, sampleRate: rate, seed: 2)

        let referenceURL = TestAudioFile.temporaryURL("silent.caf")
        let targetURL = TestAudioFile.temporaryURL("speech.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .pcm16, to: targetURL)

        let result = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 0.9)

        #expect(result.method == .coarse)
        #expect(result.isApproximate)
        #expect(result.offset == 0.9)
    }
}
