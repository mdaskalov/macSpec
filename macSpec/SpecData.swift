//
//  SpecData.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation
import Foundation
import Accelerate
import Combine

enum Source: String, CaseIterable, Identifiable {
    case audio, test, generated
    var id: Self { self }
}

class SpecData: ObservableObject {
    @Published var source: Source = .audio {
        didSet {
            if source == .audio {
                stopTimer()
            }
            else {
                startTimer()
            }
        }
    }
    @Published var samples: [Float]
    @Published var bars: [Float]
    @Published var peaks: [Float]

    let kGain: Float = 1.0

    private let kWaveformLength: Int
    private let kSpecViewLength: Int    
    
    private var barDelay:Float = 0.05;
    private var peakDelay = 50;
    
    private let fftLength: vDSP_Length
    private let fftSetup: FFTSetup?
    
    private var fftResult: [Float]
    
    private var peakTime: [Int]
       
    private var timer: AnyCancellable?
    
    init() {
        kWaveformLength = 512
        kSpecViewLength = kWaveformLength / 4

        samples = [Float](repeating: 0.0, count: kWaveformLength)
        
        barDelay = 0.05
        peakDelay = 50
        
        fftLength = vDSP_Length(log2(Float(kWaveformLength)))
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))
        fftResult = [Float](repeating: 0.0, count: kSpecViewLength)
        
        bars = [Float](repeating: 0, count: kSpecViewLength)
        peaks = [Float](repeating: 0, count: kSpecViewLength)
        peakTime = [Int](repeating: 0, count: kSpecViewLength)
    }
    
    deinit {
        if (fftSetup != nil) {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }
    
    func startTimer() {
        timer = Timer.publish(every: 0.005, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.update()
            }
    }
    
    func stopTimer() {
        timer?.cancel()
        timer = nil
    }
    
    func adjustValue(current: Float, new: Float, delay: Float) -> Float {
        if new > current || current - delay < new {
            return new
        }
        return current - delay
    }

    func update() {
        for i in 0..<kSpecViewLength {
            bars[i] = adjustValue(current: bars[i], new: fftResult[i], delay: barDelay)
            peakTime[i] += 1
            if (peakTime[i] > peakDelay) || (bars[i] > peaks[i]) {
                peakTime[i] = 0
                peaks[i] = bars[i]
            }
        }
    }
    
    func generateWaveform(phase: Double) {
        for i in 0..<samples.count {
            samples[i] = 1.0 * sin(Float(Double(i)*phase)/64.0)
        }
        calculateSpectrum()
        update()
    }
    
    func calculateSpectrum() {
        let samplesCount = samples.count
        var real = [Float](samples)
        var imag = [Float](repeating: 0.0, count: samplesCount)
        var resultRaw = [Float](repeating: 0.0, count: samplesCount)
        var result = [Float](repeating: 0.0, count: samplesCount)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                if let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress {
                    var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    if let fft = fftSetup {
                        vDSP_fft_zip(fft, &splitComplex, 1, fftLength, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, &resultRaw, 1, vDSP_Length(samplesCount))
                        vDSP_vsmul(&resultRaw, 1, [0.07 / Float(samplesCount)], &result, 1, vDSP_Length(samplesCount))
                    }
                }
            }
        }
        for i in 0..<kSpecViewLength {
            fftResult[i] = result[i].squareRoot()
        }
    }
    
}
