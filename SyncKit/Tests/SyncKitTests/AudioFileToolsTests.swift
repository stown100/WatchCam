import AVFoundation
import Foundation
import Testing
@testable import SyncKit

struct AudioFileToolsTests {
    /// Drift correction: after time-scaling by the measured ratio, the watch audio must line up
    /// with the reference along the whole take, with no drift and no added delay.
    @Test func timeScaleRemovesDrift() async throws {
        let rate = 16_000.0
        let duration = 200.0
        let world = Synth.speechLike(duration: duration + 10, sampleRate: rate, seed: 31)
        let referenceStart = 2.0
        let trueOffset = 1.5
        let trueRatio = 1.000_06

        let reference = Synth.slice(world, sampleRate: rate, start: referenceStart, duration: duration)
        let target = (0..<Int((duration + 3) * rate)).map { index -> Float in
            let u = Double(index) / rate
            return Synth.sample(world, at: ((u - trueOffset) / trueRatio + referenceStart) * rate)
        }

        let referenceURL = TestAudioFile.temporaryURL("ref.caf")
        let targetURL = TestAudioFile.temporaryURL("drifting.caf")
        let correctedURL = TestAudioFile.temporaryURL("corrected.caf")
        defer {
            [referenceURL, targetURL, correctedURL].forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try TestAudioFile.write(reference, sampleRate: rate, encoding: .pcm16, to: referenceURL)
        try TestAudioFile.write(target, sampleRate: rate, encoding: .aac, to: targetURL)

        try AudioFileTools.timeScale(input: targetURL, output: correctedURL, ratio: trueRatio)
        let result = try await SyncEngine.synchronize(reference: referenceURL, target: correctedURL, coarseOffset: trueOffset)

        #expect(result.method == .crossCorrelation)
        #expect(abs(result.driftPPM) < 3, "residual drift \(result.driftPPM) ppm")
        #expect(abs(result.offset - trueOffset / trueRatio) < 0.001, "offset \(result.offset)")
        #expect(abs(result.offset(at: duration) - trueOffset / trueRatio) < 0.001)
    }

    @Test(arguments: [0.75, -0.4])
    func alignedWAVStartsAtVideoZero(offset: Double) throws {
        let rate = 48_000.0
        // A click every second; the first one at audio time 1.0 s.
        var audio = [Float](repeating: 0, count: Int(6 * rate))
        for second in 1..<6 { audio[Int(Double(second) * rate)] = 1 }

        let inputURL = TestAudioFile.temporaryURL("clicks.caf")
        let outputURL = TestAudioFile.temporaryURL("aligned.wav")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try TestAudioFile.write(audio, sampleRate: rate, encoding: .pcm16, to: inputURL)

        let videoDuration = 4.0
        try AudioFileTools.writeAligned(input: inputURL, offset: offset, videoDuration: videoDuration, output: outputURL)

        let file = try AVAudioFile(forReading: outputURL)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        #expect(samples.count == Int(videoDuration * rate))
        // The click at audio time 1.0 s plays at video time 1.0 - offset.
        let expectedIndex = Int(((1.0 - offset) * rate).rounded())
        let firstClick = samples.firstIndex { $0 > 0.5 }
        #expect(firstClick == expectedIndex, "click at \(String(describing: firstClick)), expected \(expectedIndex)")
    }
}
