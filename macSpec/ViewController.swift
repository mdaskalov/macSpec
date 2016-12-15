//
//  ViewController.swift
//  macSpec
//
//  Created by Milko Daskalov on 26.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Cocoa

class ViewController: NSViewController {
    
    var running = true
    var generated = false
    var testFreqency: Double = 0
    
    @IBOutlet weak var waveView: WaveView!
    @IBOutlet weak var specView: SpecView!
    @IBOutlet weak var testSlider: NSSlider!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        NSTimer.scheduledTimerWithTimeInterval(1.0/60.0, target: self, selector: #selector(ViewController.redraw), userInfo: nil, repeats: true)
    }

    func redraw() {
        if (running) {
            let buffer = AudioInputHandler.sharedInstance().ringBuffers.first as! RingBuffer
            buffer.copyTo(waveView.waveform)
        }
        if (generated) {
            waveView.generateWaveform(testFreqency)
            testFreqency += 0.01
            if testFreqency > 55 {
                testFreqency = 0
            }
        }
        specView.calculateSpectrum(waveView.waveform)
        waveView.needsDisplay = true
        specView.needsDisplay = true
    }

    @IBAction func modeSelected(sender: AnyObject) {
        switch (sender as! NSSegmentedControl).selectedSegment {
        case 0:
            running = true
            generated = false
            testSlider.doubleValue = 0
            testSlider.enabled = false
        case 1:
            running = false
            generated = false
            waveView.generateWaveform(sender.doubleValue)
            specView.calculateSpectrum(waveView.waveform)
            waveView.needsDisplay = true
            testSlider.enabled = true
        case 2:
            running = false
            generated = true
            testSlider.enabled = false
        default:
            break
        }
        redraw()
    }
    
    @IBAction func updatedTestSlider(sender: NSSlider) {
        waveView.generateWaveform(sender.doubleValue)
        specView.calculateSpectrum(waveView.waveform)
        redraw()
    }
    
    @IBAction func updatedPeakSlider(sender: NSSlider) {
        specView.peakDelay = Int(sender.doubleValue)
        redraw()
    }
    
    @IBAction func updatedBarSlider(sender: NSSlider) {
        specView.barDelay = Float(sender.doubleValue) / 1000.0
        redraw()
    }
}

