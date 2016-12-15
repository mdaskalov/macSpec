//
//  WaveView.swift
//  macSpec
//
//  Created by Milko Daskalov on 26.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Cocoa

let kWaveformLength = 512
let kWaveViewLength = kWaveformLength / 4
let kGain:Float = 1

class WaveView: NSView {
    
    var waveform = [Float](count: kWaveformLength, repeatedValue: 0.0)
    
    override func drawRect(dirtyRect: NSRect) {
        super.drawRect(dirtyRect)
        
        //CATransaction.begin()
        //CATransaction.setDisableActions(true)
        
        NSRectFill(dirtyRect)
        NSColor.whiteColor().set()
        let path = NSBezierPath()
        
        let size = self.frame.size
        
        let xScale = size.width / CGFloat(kWaveViewLength);
        
        path.moveToPoint(NSMakePoint(0, CGFloat(waveform[0] * kGain * 0.5 + 0.5) * size.height))
        for i in 1...kWaveViewLength {
            let x = xScale * CGFloat(i)
            let y = CGFloat(waveform[i] * kGain * 0.5 + 0.5) * size.height
            path.lineToPoint(NSMakePoint(x, y))
        }
        path.lineWidth = 1
        path.stroke()
        //CATransaction.commit()
    }
    
    func generateWaveform(phase: Double) {
        for i in 0..<waveform.count {
            waveform[i] = 1.0 * sin(Float(Double(i)*phase)/64.0)
        }
        
    }
}
