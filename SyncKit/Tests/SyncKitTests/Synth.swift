import AVFoundation
import Accelerate
import Foundation

/// Deterministic random numbers so every test run sees the same signals.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic test signals.
enum Synth {
    /// Speech-like signal: voiced "syllables" with a wandering pitch and harmonics,
    /// noisy consonant bursts and pauses of varying length.
    static func speechLike(duration: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        let total = Int(duration * sampleRate)
        var output = [Float](repeating: 0, count: total)
        var position = Int(Double.random(in: 0.05...0.3, using: &rng) * sampleRate)

        while position < total {
            let amplitude = Float.random(in: 0.25...1.0, using: &rng)

            // Optional consonant: a short noise burst.
            if Bool.random(using: &rng) {
                let length = Int(Double.random(in: 0.02...0.07, using: &rng) * sampleRate)
                for i in 0..<length where position + i < total {
                    let envelope = sin(Float.pi * Float(i) / Float(length))
                    output[position + i] += 0.3 * amplitude * envelope * Float.random(in: -1...1, using: &rng)
                }
                position += length
            }

            // Voiced part: harmonic series with a slowly gliding pitch.
            let length = Int(Double.random(in: 0.1...0.32, using: &rng) * sampleRate)
            let startPitch = Double.random(in: 95...230, using: &rng)
            let endPitch = startPitch * Double.random(in: 0.8...1.25, using: &rng)
            let harmonics = max(1, Int(min(3_400, sampleRate * 0.45) / max(startPitch, endPitch)))
            // Each syllable gets its own harmonic phases and a crude random "vowel" colouring.
            let phases = (0..<harmonics).map { _ in Double.random(in: 0..<(2 * Double.pi), using: &rng) }
            let weights = (1...harmonics).map { h in Double.random(in: 0.3...1.0, using: &rng) / Double(h) }
            var phase = 0.0
            for i in 0..<length where position + i < total {
                let progress = Double(i) / Double(length)
                let pitch = startPitch + (endPitch - startPitch) * progress
                phase += 2 * Double.pi * pitch / sampleRate
                var sample = 0.0
                for h in 0..<harmonics {
                    sample += weights[h] * sin(Double(h + 1) * phase + phases[h])
                }
                let envelope = sin(Double.pi * progress)
                output[position + i] += Float(0.35 * Double(amplitude) * envelope * sample)
            }
            position += length

            // Pause: mostly short, sometimes a breath.
            let pause = Bool.random(using: &rng)
                ? Double.random(in: 0.04...0.25, using: &rng)
                : Double.random(in: 0.3...1.1, using: &rng)
            position += Int(pause * sampleRate)
        }
        return output
    }

    static func whiteNoise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in amplitude * Float.random(in: -1...1, using: &rng) }
    }

    /// Room impulse response: direct path plus an exponentially decaying diffuse tail.
    static func roomImpulse(sampleRate: Double, rt60: Double, directToReverbDB: Double, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        let length = Int(rt60 * sampleRate)
        let tailStart = Int(0.003 * sampleRate)
        var response = [Float](repeating: 0, count: length)
        var tailEnergy: Float = 0
        for i in tailStart..<length {
            let decay = Float(pow(10, -3 * Double(i) / Double(length)))
            response[i] = decay * Float.random(in: -1...1, using: &rng)
            tailEnergy += response[i] * response[i]
        }
        // Scale the tail so that direct / reverberant energy matches the requested ratio.
        let targetTail = Float(pow(10, -directToReverbDB / 10))
        let scale = (targetTail / tailEnergy).squareRoot()
        for i in tailStart..<length { response[i] *= scale }
        response[0] = 1
        return response
    }

    static func convolve(_ signal: [Float], with kernel: [Float]) -> [Float] {
        let padded = [Float](repeating: 0, count: kernel.count - 1) + signal
        var output = [Float](repeating: 0, count: signal.count)
        kernel.withUnsafeBufferPointer { k in
            vDSP_conv(padded, 1, k.baseAddress! + kernel.count - 1, -1,
                      &output, 1, vDSP_Length(signal.count), vDSP_Length(kernel.count))
        }
        return output
    }

    static func scaled(_ signal: [Float], by gain: Float) -> [Float] {
        signal.map { $0 * gain }
    }

    static func added(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    /// Reads `signal` at fractional positions with linear interpolation.
    static func sample(_ signal: [Float], at position: Double) -> Float {
        guard position >= 0 else { return 0 }
        let index = Int(position)
        guard index + 1 < signal.count else { return 0 }
        let fraction = Float(position - Double(index))
        return signal[index] * (1 - fraction) + signal[index + 1] * fraction
    }

    /// Slice of `signal` starting at a (possibly fractional) time.
    static func slice(_ signal: [Float], sampleRate: Double, start: Double, duration: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { sample(signal, at: start * sampleRate + Double($0)) }
    }
}

/// Writes test audio files the way the apps do.
enum TestAudioFile {
    enum Encoding {
        case pcm16
        case aac
    }

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitTests-\(UUID().uuidString)-\(name)")
    }

    static func write(_ samples: [Float], sampleRate: Double, encoding: Encoding, to url: URL) throws {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        switch encoding {
        case .pcm16:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        }

        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 8_192
        var index = 0
        while index < samples.count {
            let count = min(chunk, samples.count - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + index, count: count)
            }
            try file.write(from: buffer)
            index += count
        }
    }
}
