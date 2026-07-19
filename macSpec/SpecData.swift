//
//  SpecData.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Accelerate

enum Source: String, CaseIterable, Identifiable {
    case audio, test, generated
    var id: Self { self }
}

class SpecData: ObservableObject {
    let maxTestPhase: Double = 100.0
    let samplesCount: Int = 400
    let barsCount: Int

    var gain: Float = 1.0
    var barDelay: CGFloat = 0.05;
    var peakDelay = 50
    var testPhase: Double = 0.0 {
        didSet {
            let phase = testPhase
            let count = samplesCount
            DispatchQueue.main.async {
                self.samples = (0..<count).map { sin(CGFloat(Double($0) * phase) / 64.0) }
            }
        }
    }

    @Published var source: Source = .audio {
        didSet {
            testPhase = 0.0
            updateDisplayTimer()
        }
    }
    @Published var samples: [CGFloat]
    @Published var bars: [CGFloat]
    @Published var peaks: [CGFloat]

    private let fftLength: vDSP_Length
    private let fftSetup: FFTSetup?
    private var fftResult: [Float]

    private var peakTime: [Int]

    private var sampling: Bool = false
    private var inUpdate: Bool = false
    private var displayTimer: Timer?

    // System-audio tap: captures the mix going to the default output device
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "com.innersoft.macSpec.tap")
    private var pending = [Float]()

    init() {
        barsCount = samplesCount / 4

        samples = [CGFloat](repeating: 0.0, count: samplesCount)
        bars = [CGFloat](repeating: 0, count: barsCount)
        peaks = [CGFloat](repeating: 0, count: barsCount)

        fftLength = vDSP_Length(log2(Float(samplesCount)))
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))
        fftResult = [Float](repeating: 0.0, count: samplesCount)

        peakTime = [Int](repeating: 0, count: barsCount)
    }

    deinit {
        displayTimer?.invalidate()
        stopSampling()
        if let fft = fftSetup {
            vDSP_destroy_fftsetup(fft)
        }
    }

    func startSampling() {
        let tapDescription: CATapDescription
        if let musicProcess = findAudioProcess(bundleID: "com.apple.Music") {
            print("Tapping Apple Music")
            tapDescription = CATapDescription(monoMixdownOfProcesses: [musicProcess])
        } else {
            print("Music not running, tapping system audio")
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        tapDescription.name = "macSpec system audio tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var osStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard osStatus == noErr else {
            print("AudioHardwareCreateProcessTap failed: \(osStatus)")
            return
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "macSpec tap device",
            kAudioAggregateDeviceUIDKey: "com.innersoft.macSpec.tap",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        osStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard osStatus == noErr else {
            print("AudioHardwareCreateAggregateDevice failed: \(osStatus)")
            return
        }

        osStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, tapQueue) { [weak self] _, inInputData, _, _, _ in
            self?.processTap(bufferList: inInputData)
        }
        guard osStatus == noErr, let ioProcID = ioProcID else {
            print("AudioDeviceCreateIOProcIDWithBlock failed: \(osStatus)")
            return
        }

        osStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard osStatus == noErr else {
            print("AudioDeviceStart failed: \(osStatus)")
            return
        }
        print("Started sampling")
        sampling = true
        updateDisplayTimer()
    }

    func stopSampling() {
        if let ioProcID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        sampling = false
    }

    // Translates a bundle ID to its Core Audio process object (nil if the app isn't running)
    private func findAudioProcess(bundleID: String) -> AudioObjectID? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = app.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let osStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        guard osStatus == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObject
    }

    // Runs on tapQueue: downmix to mono and hand off full FFT-sized chunks
    private func processTap(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let floatData = data.assumingMemoryBound(to: Float.self)

        for frame in 0..<frames {
            var sum: Float = 0.0
            for channel in 0..<channels {
                sum += floatData[frame * channels + channel]
            }
            pending.append(sum / Float(channels))
        }
        while pending.count >= samplesCount {
            let chunk = Array(pending.prefix(samplesCount))
            pending.removeFirst(samplesCount)
            DispatchQueue.main.async {
                self.update(audioSamples: chunk)
            }
        }
    }

    // Drives update() from a timer when the tap can't (capture failed or non-audio source)
    private func updateDisplayTimer() {
        let needsTimer = !sampling && source != .audio
        if needsTimer && displayTimer == nil {
            displayTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                self?.update()
            }
        } else if !needsTimer, let timer = displayTimer {
            timer.invalidate()
            displayTimer = nil
        }
    }

    func adjustValue(current: CGFloat, new: Float) -> CGFloat {
        let value = (CGFloat(new) * 0.07 / CGFloat(samplesCount)).squareRoot()
        if value > current || current - barDelay < value {
            return value
        }
        return current - barDelay
    }

    func update(audioSamples: [Float]? = nil) {
        guard !inUpdate else {
            print("overrun")
            return
        }
        inUpdate = true

        var real: [Float]
        if source == .audio, var captured = audioSamples {
            if captured.count < samplesCount {
                captured += [Float](repeating: 0.0, count: samplesCount - captured.count)
            }
            real = captured
            samples = captured.map { CGFloat($0) }
        }
        else {
            real = samples.map { Float($0) }
        }

        var imag = [Float](repeating: 0.0, count: samplesCount)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                if let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress {
                    var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    if let fft = fftSetup {
                        vDSP_fft_zip(fft, &splitComplex, 1, fftLength, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, &fftResult, 1, vDSP_Length(samplesCount))
                    }
                }
            }
        }

        var newBars = bars
        var newPeaks = peaks
        for i in 0..<self.barsCount {
            newBars[i] = adjustValue(current: newBars[i], new: fftResult[i])
            peakTime[i] += 1
            if peakTime[i] > peakDelay || newBars[i] > newPeaks[i] {
                peakTime[i] = 0
                newPeaks[i] = newBars[i]
            }
        }
        bars = newBars
        peaks = newPeaks

        if self.source == .generated {
            testPhase = testPhase > maxTestPhase ? 0.0 : testPhase + 0.01
        }
        inUpdate = false
    }

}
