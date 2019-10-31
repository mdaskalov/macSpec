//
//  AudioInput.swift
//  macSpec
//
//  Created by Milko Daskalov on 08.08.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Foundation
import CoreAudio
import AudioUnit

class AudioInput : NSObject {
    
    fileprivate var auHAL: AudioComponentInstance? = nil
    
    var inputBufferList: UnsafeMutableAudioBufferListPointer
    var ringBuffers: [RingBuffer]
    var sampleRate:Float = 0.0
    
    static let sharedInstance = AudioInput()
    
    fileprivate override init() {
        var osStatus = noErr
        
        // Create an AUHAL instance.
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let component = AudioComponentFindNext(nil, &description)
        assert(component != nil, "Find input device failed: \(osStatus)")
        
        osStatus = AudioComponentInstanceNew(component!, &auHAL)
        assert(osStatus == noErr, "Crating new instance failed: \(osStatus)")
        
        // Enable the input bus, and disable the output bus.
        let kInputElement:UInt32 = 1
        let kOutputElement:UInt32 = 0
        var kInputData:UInt32 = 1
        var kOutputData:UInt32 = 0
        let ioDataSize:UInt32 = UInt32(MemoryLayout<UInt32>.size)
        
        osStatus = AudioUnitSetProperty(
            auHAL!,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            kInputElement,
            &kInputData,
            ioDataSize
        )
        assert(osStatus == noErr, "Enable input failed: \(osStatus)")
        
        osStatus = AudioUnitSetProperty(
            auHAL!,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            kOutputElement,
            &kOutputData,
            ioDataSize
        )
        assert(osStatus == noErr, "Enable output failed: \(osStatus)")
        
        // Set the unit to the default input device.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        var inputDevice = AudioDeviceID(0)
        var inputDeviceSize:UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        osStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &inputDeviceSize,
            &inputDevice
        )
        assert(osStatus == noErr, "Get default device failed: \(osStatus)")
        
        osStatus = AudioUnitSetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &inputDevice,
            inputDeviceSize
        )
        assert(osStatus == noErr, "Set the unit to the default input device failed: \(osStatus)")
        
        // Adopt the stream format.
        var deviceFormat = AudioStreamBasicDescription()
        var desiredFormat = AudioStreamBasicDescription()
        var ioFormatSize:UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        osStatus = AudioUnitGetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Input),
            kInputElement,
            &deviceFormat,
            &ioFormatSize
        )
        assert(osStatus == noErr, "Get input format failed: \(osStatus)")
        
        osStatus = AudioUnitGetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Output),
            kInputElement,
            &desiredFormat,
            &ioFormatSize
        )
        assert(osStatus == noErr, "Get output format failed: \(osStatus)")
        
        // Same sample rate, same number of channels.
        desiredFormat.mSampleRate = deviceFormat.mSampleRate
        desiredFormat.mChannelsPerFrame = deviceFormat.mChannelsPerFrame
        
        // Canonical audio format.
        desiredFormat.mFormatID = kAudioFormatLinearPCM
        desiredFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        desiredFormat.mFramesPerPacket = 1
        desiredFormat.mBytesPerFrame = UInt32(MemoryLayout<Float32>.size)
        desiredFormat.mBytesPerPacket = UInt32(MemoryLayout<Float32>.size)
        desiredFormat.mBitsPerChannel = 8 * UInt32(MemoryLayout<Float32>.size)
        
        osStatus = AudioUnitSetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Output),
            kInputElement,
            &desiredFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        assert(osStatus == noErr, "Set output format failed: \(osStatus)")
        
        // Store the format information.
        sampleRate = Float(desiredFormat.mSampleRate)
        
        // Get the buffer frame size.
        var bufferSizeFrames: UInt32 = 0
        var bufferSizeFramesSize = UInt32(MemoryLayout<UInt32>.size)
        
        osStatus = AudioUnitGetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioDevicePropertyBufferFrameSize),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &bufferSizeFrames,
            &bufferSizeFramesSize
        )
        assert(osStatus == noErr, "Get buffer frame size failed: \(osStatus)")
        
        // Allocate the input buffer.
        let bufferSizeBytes = bufferSizeFrames * UInt32(MemoryLayout<Float32>.size)
        let channels = deviceFormat.mChannelsPerFrame
        
        inputBufferList = AudioBufferList.allocate(maximumBuffers: Int(channels))
        for i in 0..<Int(channels) {
            inputBufferList[i] = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(bufferSizeBytes),
                mData: malloc(Int(bufferSizeBytes))
            )
        }

        // Initialize the ring buffers.
        ringBuffers = [RingBuffer](repeating: RingBuffer(), count: Int(channels))
        
        super.init()
        
        // Set up the input callback.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (
                inRefCon: UnsafeMutableRawPointer,
                ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                inTimeStamp: UnsafePointer<AudioTimeStamp>,
                inBusNumber: UInt32,
                inNumberFrame: UInt32,
                ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
                
                let owner = Unmanaged<AudioInput>.fromOpaque(inRefCon).takeUnretainedValue()
                owner.inputCallback(
                    ioActionFlags: ioActionFlags,
                    inTimeStamp: inTimeStamp,
                    inBusNumber: inBusNumber,
                    inNumberFrame: inNumberFrame
                )
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
 
        osStatus = AudioUnitSetProperty(
            auHAL!,
            AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        assert(osStatus == noErr, "Set input callback failed: \(osStatus)")

        // Complete the initialization.
        osStatus = AudioUnitInitialize(auHAL!);
        assert(osStatus == noErr, "Audio unit inizialisation failed: \(osStatus)")
    }
    
    deinit {
        AudioComponentInstanceDispose(auHAL!)
        for buffer in inputBufferList {
            free(buffer.mData)
        }
        free(&inputBufferList)
    }
    
    func inputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrame: UInt32) {

        let err = AudioUnitRender(
            auHAL!,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrame,
            inputBufferList.unsafeMutablePointer
        )
        if err == noErr {
            for (i,buffer) in inputBufferList.enumerated() {
                if let buf = buffer.mData?.assumingMemoryBound(to: Float32.self) {
                    ringBuffers[i].pushSamples(buf, count: Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size)
                }
            }
        }
    }
    
    func start() {
        assert(AudioOutputUnitStart(auHAL!) == noErr, "Failed to start the audio unit.")
        
    }
    
    func stop() {
        assert(AudioOutputUnitStop(auHAL!) == noErr, "Failed to stop the audio unit.")
    }

}
