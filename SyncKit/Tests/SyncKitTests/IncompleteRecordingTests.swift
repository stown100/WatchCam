import AVFoundation
import Foundation
import Testing
@testable import SyncKit

/// A watch recording can stop early or have holes: the app may die, or the microphone may stop
/// while the watch is locked. The video must stay whole and in sync anyway.
struct IncompleteRecordingTests {
    private func expectRanges(_ actual: [ClosedRange<Double>], _ expected: [ClosedRange<Double>],
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, "got \(actual)", sourceLocation: sourceLocation)
        for (a, b) in zip(actual, expected) {
            #expect(abs(a.lowerBound - b.lowerBound) < 1e-9 && abs(a.upperBound - b.upperBound) < 1e-9,
                    "got \(actual), expected \(expected)", sourceLocation: sourceLocation)
        }
    }

    @Test func aCompleteTakeNeedsNothing() {
        // The watch started 0.4 s before the video and stopped 0.3 s after it.
        expectRanges(AudioCoverage.missing(videoDuration: 60, audioDuration: 60.7, gaps: [], offset: 0.4), [])
        // Started a little late: a normal trim, not a reason to change microphones.
        expectRanges(AudioCoverage.missing(videoDuration: 60, audioDuration: 59.5, gaps: [], offset: -0.5), [])
        // A blip.
        expectRanges(AudioCoverage.missing(videoDuration: 60, audioDuration: 60, gaps: [10...10.1], offset: 0), [])
    }

    @Test func aRecordingThatStoppedEarly() {
        // The case behind all this: a 9:40 video, with the watch stopping after two minutes.
        expectRanges(AudioCoverage.missing(videoDuration: 580, audioDuration: 120, gaps: [], offset: 0.3), [119.7...580])
        // A small edge joins in once filling is happening anyway.
        expectRanges(AudioCoverage.missing(videoDuration: 580, audioDuration: 120, gaps: [], offset: -0.4), [0...0.4, 120.4...580])
    }

    @Test func holesAreMovedOntoTheVideoTimeline() {
        expectRanges(AudioCoverage.missing(videoDuration: 100, audioDuration: 102, gaps: [10...20, 50...60], offset: 2),
                     [8...18, 48...58])
        // The file ending 2 s before the video counts too, since filling is happening anyway.
        expectRanges(AudioCoverage.missing(videoDuration: 100, audioDuration: 100, gaps: [10...20], offset: 2),
                     [8...18, 98...100])
        // A hole running into the end joins the end.
        expectRanges(AudioCoverage.missing(videoDuration: 100, audioDuration: 50, gaps: [40...50], offset: 0), [40...100])
    }

    @Test func noOverlapAtAll() {
        expectRanges(AudioCoverage.missing(videoDuration: 30, audioDuration: 10, gaps: [], offset: 100), [0...30])
    }

    @Test func longestSoundSpan() {
        #expect(AudioCoverage.longestSoundSpan(audioDuration: 100, gaps: []) == 0...100)
        #expect(AudioCoverage.longestSoundSpan(audioDuration: 100, gaps: [10...20, 40...90]) == 20...40)
        #expect(AudioCoverage.longestSoundSpan(audioDuration: 100, gaps: [0...90]) == 90...100)
    }

    /// The real shape of the problem: the file says "uncompressed, length unknown" because it was
    /// never closed. Sync has to work on the part that exists.
    @Test func syncOnARecordingShorterThanTheVideo() async throws {
        let rate = 48_000.0
        let world = Synth.speechLike(duration: 130, sampleRate: rate, seed: 11)
        let reference = Synth.scaled(Synth.slice(world, sampleRate: rate, start: 2, duration: 120), by: 0.1)
        // Watch started 1.5 s before the video and stopped after 40 s.
        let target = Synth.slice(world, sampleRate: rate, start: 0.5, duration: 40)

        let referenceURL = TestAudioFile.temporaryURL("reference.caf")
        let targetURL = TestAudioFile.temporaryURL("target.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .pcm16, to: targetURL)

        let result = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 1.5 + 0.7)

        #expect(result.method == .crossCorrelation)
        #expect(abs(result.offset - 1.5) < 0.002, "offset \(result.offset)")
    }

    /// Sound only in one stretch, inserted silence around it. Analysis windows are spread over the
    /// whole take, so they can all miss that stretch unless told where it is.
    @Test func syncStaysAwayFromInsertedSilence() async throws {
        let rate = 16_000.0
        let world = Synth.speechLike(duration: 210, sampleRate: rate, seed: 12)
        let reference = Synth.scaled(Synth.slice(world, sampleRate: rate, start: 2, duration: 200), by: 0.1)
        var target = Synth.slice(world, sampleRate: rate, start: 0.5, duration: 200)
        for index in target.indices where index < Int(45 * rate) || index >= Int(75 * rate) { target[index] = 0 }

        let referenceURL = TestAudioFile.temporaryURL("reference.caf")
        let targetURL = TestAudioFile.temporaryURL("target.caf")
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .pcm16, to: targetURL)

        let result = try await SyncEngine.synchronize(
            reference: referenceURL, target: targetURL, coarseOffset: 1.5 + 0.7, soundSpan: 45...75)

        #expect(result.method == .crossCorrelation)
        #expect(abs(result.offset - 1.5) < 0.002, "offset \(result.offset)")

        let unguided = try await SyncEngine.synchronize(reference: referenceURL, target: targetURL, coarseOffset: 1.5 + 0.7)
        #expect(unguided.method == .coarse, "windows \(unguided.windows.map { ($0.referenceTime, $0.isReliable) })")
    }

    /// How closely `signal` follows `expected` over a stretch of time: 1 means the same shape.
    private func similarity(_ signal: [Float], _ expected: [Float], from start: Double, to end: Double, rate: Double) -> (correlation: Float, levelRatio: Float) {
        let first = Int(start * rate), last = min(Int(end * rate), min(signal.count, expected.count))
        var product: Float = 0, a: Float = 0, b: Float = 0
        for index in first..<last {
            product += signal[index] * expected[index]
            a += signal[index] * signal[index]
            b += expected[index] * expected[index]
        }
        return (product / max((a * b).squareRoot(), 1e-9), (a / max(b, 1e-9)).squareRoot())
    }

    @Test func fillingKeepsTheWholeVideoInPlace() async throws {
        let rate = 48_000.0
        let duration = 60.0
        // What really happened in the room, as heard at the speaker.
        let world = Synth.speechLike(duration: duration + 5, sampleRate: rate, seed: 21)
        let truth = Synth.slice(world, sampleRate: rate, start: 2, duration: duration)

        // The video heard it from far away: much quieter.
        let phone = Synth.scaled(truth, by: 0.2)
        // The watch started 1.5 s before the video, stopped after 30 s and has a hole 10 s in.
        var watch = Synth.slice(world, sampleRate: rate, start: 0.5, duration: 30)
        for index in Int(10 * rate)..<Int(20 * rate) { watch[index] = 0 }

        let videoURL = TestAudioFile.temporaryURL("video.caf")
        let watchURL = TestAudioFile.temporaryURL("watch.caf")
        let outputURL = TestAudioFile.temporaryURL("filled.caf")
        defer {
            for url in [videoURL, watchURL, outputURL] { try? FileManager.default.removeItem(at: url) }
        }
        try TestAudioFile.write(phone, sampleRate: rate, encoding: .pcm16, to: videoURL)
        try TestAudioFile.write(watch, sampleRate: rate, encoding: .pcm16, to: watchURL)

        let missing = AudioCoverage.missing(videoDuration: duration, audioDuration: 30, gaps: [10...20], offset: 1.5)
        expectRanges(missing, [8.5...18.5, 28.5...60])

        try await AudioFileTools.fillMissing(
            watch: watchURL, offset: 1.5, missing: missing, video: videoURL, videoDuration: duration, output: outputURL)

        let result = try await AudioDecoder.decodeMono(url: outputURL, sampleRate: rate)
        #expect(abs(result.duration - duration) < 0.05, "duration \(result.duration)")

        // Every part lines up with what happened, at the same level, wherever it came from.
        let parts: [(String, Double, Double)] = [
            ("watch, start", 1, 8), ("phone, hole", 9.5, 17.5), ("watch, middle", 19.5, 27.5), ("phone, end", 30, 58),
        ]
        for (name, start, end) in parts {
            let match = similarity(result.samples, truth, from: start, to: end, rate: rate)
            #expect(match.correlation > 0.97, "\(name): correlation \(match.correlation)")
            #expect(abs(match.levelRatio - 1) < 0.2, "\(name): level ratio \(match.levelRatio)")
        }
    }
}
