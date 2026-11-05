import Accelerate

/// FFT-based cross-correlation with optional generalized PHAT weighting.
enum FFTCorrelator {
    struct Options {
        /// 0 = plain cross-correlation, 1 = full PHAT (phase transform) whitening.
        /// Partial whitening keeps the peak sharp under reverb while not blowing up empty bands.
        var phatBeta: Float
        var minFrequency: Double
        var maxFrequency: Double
        var sampleRate: Double
    }

    /// Computes `r[k] = Σ_t a[t] · b[t + k]` for every lag `k`.
    ///
    /// The result is circular with length `n >= a.count + b.count`, so nothing wraps:
    /// lag `k >= 0` lives at index `k`, lag `k < 0` lives at index `n + k`.
    static func crossCorrelate(_ a: [Float], _ b: [Float], options: Options) -> [Float] {
        let needed = a.count + b.count
        var log2n = 1
        while (1 << log2n) < needed { log2n += 1 }
        let n = 1 << log2n

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var aRe = [Float](repeating: 0, count: n)
        var aIm = [Float](repeating: 0, count: n)
        var bRe = [Float](repeating: 0, count: n)
        var bIm = [Float](repeating: 0, count: n)
        aRe.replaceSubrange(0..<a.count, with: a)
        bRe.replaceSubrange(0..<b.count, with: b)

        let binWidth = options.sampleRate / Double(n)
        let beta = options.phatBeta

        aRe.withUnsafeMutableBufferPointer { aReP in
            aIm.withUnsafeMutableBufferPointer { aImP in
                bRe.withUnsafeMutableBufferPointer { bReP in
                    bIm.withUnsafeMutableBufferPointer { bImP in
                        var A = DSPSplitComplex(realp: aReP.baseAddress!, imagp: aImP.baseAddress!)
                        var B = DSPSplitComplex(realp: bReP.baseAddress!, imagp: bImP.baseAddress!)
                        vDSP_fft_zip(setup, &A, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        vDSP_fft_zip(setup, &B, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))

                        // Cross-spectrum G = conj(A) · B, written into B.
                        vDSP_zvmul(&A, 1, &B, 1, &B, 1, vDSP_Length(n), -1)

                        // Band-limit and whiten. Bins k and n-k are mirror frequencies.
                        let re = bReP.baseAddress!
                        let im = bImP.baseAddress!
                        for k in 0..<n {
                            let frequency = Double(min(k, n - k)) * binWidth
                            if frequency < options.minFrequency || frequency > options.maxFrequency {
                                re[k] = 0
                                im[k] = 0
                                continue
                            }
                            if beta > 0 {
                                let magnitude = (re[k] * re[k] + im[k] * im[k]).squareRoot()
                                let weight = 1 / (powf(magnitude, beta) + 1e-20)
                                re[k] *= weight
                                im[k] *= weight
                            }
                        }

                        vDSP_fft_zip(setup, &B, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                    }
                }
            }
        }
        // The real part of the inverse transform is the (unnormalized) correlation.
        return bRe
    }
}
