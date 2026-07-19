//
//  SpecData.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation
import AudioToolbox
import Accelerate

enum Source: String, CaseIterable, Identifiable {
    case audio, test, generated
    var id: Self { self }
}

func aqInputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inStartTime: UnsafePointer<AudioTimeStamp>,
    inNumPackets: UInt32,
    inPacketDesc: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let inUserData = inUserData else { return }
    let specData = Unmanaged<SpecData>.fromOpaque(inUserData).takeUnretainedValue()
    if let userData = inBuffer.pointee.mUserData {
        let indexPointer = userData.assumingMemoryBound(to: Int.self)
        let bufIndex = indexPointer.pointee
        DispatchQueue.main.async {
            specData.update(bufIndex: bufIndex)
        }
    }
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
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
    private var audioQueue: AudioQueueRef?
    private var buffers = [AudioQueueBufferRef?](repeating: nil, count: 4)
    private var audioFormat = AudioStreamBasicDescription()
    
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
        stopSampling()
        if let fft = fftSetup {
            vDSP_destroy_fftsetup(fft)
        }
    }
    
    func startSampling() {
        print("Started sampling")
        audioFormat.mSampleRate = 22050.0
        audioFormat.mChannelsPerFrame = 1
        
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)

        // Canonical audio format.
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        audioFormat.mFramesPerPacket = 1
        audioFormat.mBytesPerFrame = bytesPerSample
        audioFormat.mBytesPerPacket = bytesPerSample
        audioFormat.mBitsPerChannel = 8 * bytesPerSample

        // Create the AudioQueue and pass self as user data
        var osStatus = AudioQueueNewInput(
            &audioFormat,
            aqInputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &audioQueue
        )
        guard osStatus == noErr else {
            print("AudioQueueNewInput failed: \(osStatus)")
            return
        }
        if let aq = audioQueue {
            // Allocate and enqueue buffers
            let bufferByteSize: UInt32 = UInt32(samplesCount) * bytesPerSample
            for i in 0..<buffers.count {
                osStatus = AudioQueueAllocateBuffer(aq, bufferByteSize, &buffers[i])
                guard osStatus == noErr else {
                    print("AudioQueueAllocateBuffer failed: \(osStatus)")
                    return
                }
                if let buffer = buffers[i] {
                    osStatus = AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
                    guard osStatus == noErr else {
                        print("AudioQueueEnqueueBuffer failed: \(osStatus)")
                        return
                    }
                    let indexPointer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                    indexPointer.pointee = i
                    buffer.pointee.mUserData = UnsafeMutableRawPointer(indexPointer)
                }
            }
            osStatus = AudioQueueStart(aq, nil)
            guard osStatus == noErr else {
                print("AudioQueueStart failed: \(osStatus)")
                return
            }
            sampling = true
        }
    }
    
    func stopSampling()  {
        if let aq = audioQueue {
            var osStatus = AudioQueueStop(aq, false)
            guard osStatus == noErr else {
                print("AudioQueueStop failed: \(osStatus)")
                return
            }
            osStatus = AudioQueueDispose(aq, false)
            guard osStatus == noErr else {
                print("AudioQueueDispose failed: \(osStatus)")
                return
            }
            audioQueue = nil
            sampling = false
        }
        for buffer in buffers {
            if let buf = buffer, let userData = buf.pointee.mUserData {
                let indexPointer = userData.assumingMemoryBound(to: Int.self)
                indexPointer.deallocate() // Deallocate the memory
            }
        }
        buffers.removeAll()
    }
    
    func adjustValue(current: CGFloat, new: Float) -> CGFloat {
        let value = (CGFloat(new) * 0.07 / CGFloat(samplesCount)).squareRoot()
        if value > current || current - barDelay < value {
            return value
        }
        return current - barDelay
    }
    
    func update(bufIndex: Int) {
        guard bufIndex < buffers.count else { return }
        guard !inUpdate else {
            print("overrun")
            return
        }
        inUpdate = true

        var real: [Float]
        
        if source != .audio {
            real = [Float](repeating: 0.0, count: samplesCount)
            for i in 0..<samples.count {
                real[i] = Float(samples[i])
            }
        }
        else if let inBuffer = buffers[bufIndex] {
            let audioData = inBuffer.pointee.mAudioData
            let bufSamples = Int(inBuffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            let copyCount = min(samplesCount, bufSamples)
            real = [Float](repeating: 0.0, count: samplesCount)
            audioData.withMemoryRebound(to: Float.self, capacity: copyCount) { floatPointer in
                for i in 0..<copyCount {
                    real[i] = floatPointer[i]
                }
            }
            samples = real.map { CGFloat($0) }
        }
        else {
            real = [Float](repeating: 0.0, count: samplesCount)
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
