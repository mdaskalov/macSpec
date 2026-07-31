//
//  FFTBand.swift
//  macSpec
//
//  Created by Milko Daskalov on 23.07.26.
//  Copyright © 2026 Milko Daskalov. All rights reserved.
//

import Accelerate

// Owns one FFT's setup, window and output magnitudes. Caching the window here
// lets it survive across calls: it only rebuilds when the real sample count
// changes, which stops once the rolling buffer fills.
final class FFTBand {
    let size: Int
    // Highest bin holding a positive frequency (size/2 is Nyquist).
    let maxBin: Int
    private(set) var magnitudes: [Float]
    // |X|^2 a full-scale, bin-aligned sine yields for the sample count last
    // windowed (Hann coherent gain ~0.5, so it peaks at count * 0.5 / 2).
    private(set) var referenceMagnitude: Float = 1

    private let length: vDSP_Length
    private let setup: FFTSetup?
    private var real: [Float]
    private var imag: [Float]
    private var window: [Float] = []

    init(size: Int) {
        self.size = size
        maxBin = size / 2
        length = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(length, FFTRadix(kFFTRadix2))
        real = [Float](repeating: 0, count: size)
        imag = [Float](repeating: 0, count: size)
        magnitudes = [Float](repeating: 0, count: size)
    }

    deinit {
        if let setup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // Transforms the most recent `size` samples of source - its tail, so a
    // longer source still yields current audio rather than the oldest held.
    func analyze(_ source: [Float]) {
        let count = min(source.count, size)
        guard count > 0 else {
            vDSP_vclr(&magnitudes, 1, vDSP_Length(size))
            referenceMagnitude = 1
            return
        }
        if window.count != count {
            window = Processor.hannWindow(length: count)
        }
        let start = source.count - count
        // imag must be cleared each call (in-place transform); real is cleared
        // unconditionally to zero its padded tail in one memset.
        vDSP_vclr(&real, 1, vDSP_Length(size))
        vDSP_vclr(&imag, 1, vDSP_Length(size))
        source.withUnsafeBufferPointer { sourcePtr in
            vDSP_vmul(sourcePtr.baseAddress! + start, 1, window, 1, &real, 1, vDSP_Length(count))
        }
        referenceMagnitude = pow(Float(count) * 0.25, 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                magnitudes.withUnsafeMutableBufferPointer { magPtr in
                    guard let setup else { return }
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_fft_zip(setup, &splitComplex, 1, length, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&splitComplex, 1, magPtr.baseAddress!, 1, vDSP_Length(size))
                }
            }
        }
    }
}
