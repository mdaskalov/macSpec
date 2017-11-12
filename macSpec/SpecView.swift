//
//  SpecView.swift
//  macSpec
//
//  Created by Milko Daskalov on 28.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Cocoa
import Foundation
import Accelerate

let kSpecViewLength = kWaveformLength / 4

class SpecView: NSView {

    var barDelay:Float = 0.05;
    var peakDelay = 50;
    
    let fftLength = vDSP_Length(log2(Float(kWaveformLength)))
    let fftSetup: FFTSetup
    
    var fftResult = [Float](repeating: 0.0, count: kWaveformLength)
    var bar = [Float](repeating: 0, count: kSpecViewLength)
    var peak = [Float](repeating: 0, count: kSpecViewLength)
    var peakTime = [Int](repeating: 0, count: kSpecViewLength)
  
    /*
    var maxFrequency: Float {
        get {
            var res:Float = 0
            var maxValue:Float = 0
            var maxIndex:vDSP_Length = 0
            
            vDSP_maxvi(&fftResult, 1, &maxValue, &maxIndex, vDSP_Length(fftResult.count))
            
            if maxValue > 0.01 {
                let maxFreq = AudioInputHandler.sharedInstance().sampleRate;
                res = Float(maxIndex) / Float(fftResult.count) * maxFreq;
            }
            return res
        }
    }
    */
    
    required init?(coder: NSCoder) {
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))!
        
        super.init(coder: coder)
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        NSColor.black.setFill()
        dirtyRect.fill()
        NSColor.yellow.setFill()
        NSColor.red.setStroke()
        let path = NSBezierPath()
        
        let size = self.frame.size
        let barGap: CGFloat = (size.width) / CGFloat(kSpecViewLength) / 10
        let barWidth:CGFloat = (size.width - CGFloat(kSpecViewLength+1) * barGap) / CGFloat(kSpecViewLength)
        let xAdjust = barWidth + barGap
        let yAdjust = size.height - barGap
        
        for i in 0..<kSpecViewLength {
            let barValue = fftResult[i] > 1.0 ? 1.0 : fftResult[i]
            bar[i] = barValue >= bar[i] ? barValue : bar[i] - barDelay

            let x = barGap + CGFloat(i) * xAdjust
            let y = CGFloat(bar[i]) * yAdjust;
            let yPeak = CGFloat(peak[i]) * yAdjust;

            peakTime[i] += 1
            if (peakTime[i] > peakDelay) || (bar[i] > peak[i]) {
                peakTime[i] = 0
                peak[i] = bar[i]
            }

            if (yPeak > y) {
                path.move(to: NSMakePoint(x, yPeak))
                path.line(to: NSMakePoint(x+barWidth, yPeak))
            }
            NSMakeRect(x, barGap, barWidth, y-barGap).fill();
        }
        path.lineWidth = 1
        path.stroke()
    }

    func calculateSpectrum(_ waveform: [Float]) {
        var real = [Float](waveform)
        var imag = [Float](repeating: 0.0, count: real.count)
        
        var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)
        
        var fftResultRaw = [Float](repeating: 0.0, count: real.count)
        
        vDSP_fft_zip(fftSetup, &splitComplex, 1, fftLength, FFTDirection(FFT_FORWARD))
        
        vDSP_zvmags(&splitComplex, 1, &fftResultRaw, 1, vDSP_Length(fftResultRaw.count))
        
        vDSP_vsmul(&fftResultRaw, 1, [0.07 / Float(fftResult.count)], &fftResult, 1, vDSP_Length(fftResult.count))
    }
    
}
