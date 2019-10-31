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
        Timer.scheduledTimer(timeInterval: 1.0/60.0, target: self, selector: #selector(ViewController.redraw), userInfo: nil, repeats: true)
    }

    @objc func redraw() {
        if (running) {
            if let buffer = AudioInput.sharedInstance.ringBuffers.first {
                buffer.copyTo(waveView.waveform)
            }
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

    @IBAction func modeSelected(_ sender: AnyObject) {
        switch (sender as! NSSegmentedControl).selectedSegment {
        case 0:
            running = true
            generated = false
            testSlider.doubleValue = 0
            testSlider.isEnabled = false
        case 1:
            running = false
            generated = false
            waveView.generateWaveform(sender.doubleValue)
            specView.calculateSpectrum(waveView.waveform)
            waveView.needsDisplay = true
            testSlider.isEnabled = true
        case 2:
            running = false
            generated = true
            testSlider.isEnabled = false
        default:
            break
        }
        redraw()
    }
    
    @IBAction func updatedTestSlider(_ sender: NSSlider) {
        waveView.generateWaveform(sender.doubleValue)
        specView.calculateSpectrum(waveView.waveform)
        redraw()
    }
    
    @IBAction func updatedPeakSlider(_ sender: NSSlider) {
        specView.peakDelay = Int(sender.doubleValue)
        redraw()
    }
    
    @IBAction func updatedBarSlider(_ sender: NSSlider) {
        specView.barDelay = Float(sender.doubleValue) / 1000.0
        redraw()
    }
}

