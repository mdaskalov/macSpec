//
//  AudioInput.swift
//  macSpec
//
//  Created by Milko Daskalov on 08.08.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Foundation
import CoreAudio

class AudioInput : NSObject {
    
    private var au: AudioComponentInstance = nil
    
    var inputBufferList: AudioBufferList
    var ringBuffers: [RingBuffer]
    var sampleRate:Float = 0.0
    
    static let sharedInstance = AudioInput()
    
    private override init() {
        var osStatus = noErr
        
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let component = AudioComponentFindNext(nil, &description)
        assert(component != nil, "Find input device failed: \(osStatus)")
        
        osStatus = AudioComponentInstanceNew(component, &au)
        assert(osStatus == noErr, "Crating new instance failed: \(osStatus)")
        
        let kInput:UInt32 = 1
        let kOutput:UInt32 = 0
        var enable:UInt32 = 1
        var disable:UInt32 = 0
        
        osStatus = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInput, &enable, UInt32(sizeof(UInt32)))
        assert(osStatus == noErr, "Enable input failed: \(osStatus)")
        
        osStatus = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutput, &disable, UInt32(sizeof(UInt32)))
        assert(osStatus == noErr, "Enable output failed: \(osStatus)")
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        var inputDevice = AudioDeviceID(0)
        var inputDeviceSize:UInt32 = UInt32(sizeof(AudioDeviceID))

        
        osStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &inputDeviceSize, &inputDevice)
        assert(osStatus == noErr, "Get default device failed: \(osStatus)")
        
        osStatus = AudioUnitSetProperty(
            au,
            AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &inputDevice,
            UInt32(sizeof(AudioDeviceID))
        )
        assert(osStatus == noErr, "Set the unit to the default input device failed: \(osStatus)")
        
        var inputFormat = AudioStreamBasicDescription()
        var inputFormatSize:UInt32 = UInt32(sizeof(AudioStreamBasicDescription))
        var outputFormat = AudioStreamBasicDescription()
        
        osStatus = AudioUnitGetProperty(
            au,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Input),
            kInput,
            &inputFormat,
            &inputFormatSize
        )
        assert(osStatus == noErr, "Get input device format failed: \(osStatus)")
        
        osStatus = AudioUnitGetProperty(
            au,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Output),
            kOutput,
            &outputFormat,
            &inputFormatSize
        )
        assert(osStatus == noErr, "Get output format failed: \(osStatus)")
        
        outputFormat.mSampleRate = inputFormat.mSampleRate
        outputFormat.mChannelsPerFrame = inputFormat.mChannelsPerFrame
        
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerFrame = UInt32(sizeof(Float))
        outputFormat.mBytesPerPacket = UInt32(sizeof(Float))
        outputFormat.mBitsPerChannel = 8 * UInt32(sizeof(Float))
        
        osStatus = AudioUnitSetProperty(
            au,
            AudioUnitPropertyID(kAudioUnitProperty_StreamFormat),
            AudioUnitScope(kAudioUnitScope_Output),
            kInput,
            &outputFormat,
            UInt32(sizeof(AudioStreamBasicDescription))
        )
        assert(osStatus == noErr, "Set output format failed: \(osStatus)")
        
        sampleRate = Float(outputFormat.mSampleRate)
        
        var bufferSizeFrames: UInt32 = 0
        var bufferSizeFramesSize = UInt32(sizeof(UInt32))
        
        osStatus = AudioUnitGetProperty(
            au,
            AudioUnitPropertyID(kAudioDevicePropertyBufferFrameSize),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &bufferSizeFrames,
            &bufferSizeFramesSize
        )
        assert(osStatus == noErr, "Get buffer frame size failed: \(osStatus)")
        
        let bufferSizeBytes:UInt32 = bufferSizeFrames * UInt32(sizeof(Float))
        let channels:UInt32 = inputFormat.mChannelsPerFrame
        
        var buffer = [Float](count: Int(bufferSizeBytes), repeatedValue: 0)
        inputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(buffer.count),
                mData: &buffer
            )  
        )
        
        /*
         _inputBufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * channels);
         _inputBufferList->mNumberBuffers = channels;
         
         for (UInt32 i = 0; i < channels; i++) {
         AudioBuffer *buffer = &_inputBufferList->mBuffers[i];
         buffer->mNumberChannels = 1;
         buffer->mDataByteSize = bufferSizeBytes;
         buffer->mData = malloc(bufferSizeBytes);
         }
         */
        
        ringBuffers = [RingBuffer](count: Int(channels), repeatedValue: RingBuffer())
        
        super.init()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (
                inRefCon: UnsafeMutablePointer<Void>,
                ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                inTimeStamp: UnsafePointer<AudioTimeStamp>,
                inBusNumber: UInt32,
                inNumberFrame: UInt32,
                ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus in
                
                //let audioInput_nok = UnsafeMutablePointer<AudioInput>(inRefCon).memory
                let audioInput = Unmanaged<AudioInput>.fromOpaque(COpaquePointer(inRefCon)).takeUnretainedValue()

                let err = AudioUnitRender(
                    audioInput.au,
                    ioActionFlags,
                    inTimeStamp,
                    inBusNumber,
                    inNumberFrame,
                    ioData
                )
                
                if err == noErr {
                    var i = 0
                    for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                        audioInput.ringBuffers[i].pushSamples(UnsafeMutablePointer<Float>(buffer.mData), count: Int(buffer.mDataByteSize) / sizeof(Float))
                        i += 1
                    }
                }

                return err
            },
            inputProcRefCon: UnsafeMutablePointer(unsafeAddressOf(self))
        )
 
        osStatus = AudioUnitSetProperty(
            au,
            AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &callbackStruct,
            UInt32(sizeof(AURenderCallbackStruct))
        )
        assert(osStatus == noErr, "Set input callback failed: \(osStatus)")

        osStatus = AudioUnitInitialize(au);
        assert(osStatus == noErr, "Audio unit inizialisation failed: \(osStatus)")

    }
    
    
    deinit {
        AudioComponentInstanceDispose(au)
    }
    
    func start() {
        assert(AudioOutputUnitStart(au) == noErr, "Failed to start the audio unit.")
        
    }
    
    func stop() {
        assert(AudioOutputUnitStop(au) == noErr, "Failed to stop the audio unit.")
    }
    
    /*
     init() {
     
     var status: OSStatus
     
     do {
     try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(preferredIOBufferDuration)
     } catch let error as NSError {
     print(error)
     }
     
     
     var desc: AudioComponentDescription = AudioComponentDescription()
     desc.componentType = kAudioUnitType_Output
     desc.componentSubType = kAudioUnitSubType_VoiceProcessingIO
     desc.componentFlags = 0
     desc.componentFlagsMask = 0
     desc.componentManufacturer = kAudioUnitManufacturer_Apple
     
     let inputComponent: AudioComponent = AudioComponentFindNext(nil, &desc)
     
     status = AudioComponentInstanceNew(inputComponent, &audioUnit)
     checkStatus(status)
     
     var flag = UInt32(1)
     status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &flag, UInt32(sizeof(UInt32)))
     checkStatus(status)
     
     status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &flag, UInt32(sizeof(UInt32)))
     checkStatus(status)
     
     var audioFormat: AudioStreamBasicDescription! = AudioStreamBasicDescription()
     audioFormat.mSampleRate = 8000
     audioFormat.mFormatID = kAudioFormatLinearPCM
     audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
     audioFormat.mFramesPerPacket = 1
     audioFormat.mChannelsPerFrame = 1
     audioFormat.mBitsPerChannel = 16
     audioFormat.mBytesPerPacket = 2
     audioFormat.mBytesPerFrame = 2
     
     status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &audioFormat, UInt32(sizeof(UInt32)))
     checkStatus(status)
     
     
     try! AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayAndRecord)
     status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, UInt32(sizeof(UInt32)))
     checkStatus(status)
     
     
     // Set input/recording callback
     var inputCallbackStruct = AURenderCallbackStruct(inputProc: recordingCallback, inputProcRefCon: UnsafeMutablePointer(unsafeAddressOf(self)))
     
     AudioUnitSetProperty(audioUnit, AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback), AudioUnitScope(kAudioUnitScope_Global), 1, &inputCallbackStruct, UInt32(sizeof(AURenderCallbackStruct)))
     
     
     // Set output/renderar/playback callback
     var renderCallbackStruct = AURenderCallbackStruct(inputProc: playbackCallback, inputProcRefCon: UnsafeMutablePointer(unsafeAddressOf(self)))
     AudioUnitSetProperty(audioUnit, AudioUnitPropertyID(kAudioUnitProperty_SetRenderCallback), AudioUnitScope(kAudioUnitScope_Global), 0, &renderCallbackStruct, UInt32(sizeof(AURenderCallbackStruct)))
     
     
     flag = 0
     status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, kInputBus, &flag, UInt32(sizeof(UInt32)))
     }
     */
    
    
}