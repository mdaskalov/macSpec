//
//  Processor.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

// Captures system audio, runs the FFT, mel-bins it into bars and eases them into
// the frame at display rate. Reads every constant from `configuration`; writes
// only into `frame`.
final class Processor: ObservableObject {
    // True while Xcode renders a SwiftUI preview, where sampling would prompt for
    // audio permission on every refresh - so the tap only runs in the real app.
    static var isRunningForPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    let configuration: Configuration
    let frame: FrameData

    private let band: FFTBand
    // Hz -> bin layout, fixed once: the aggregate is pinned to a constant rate.
    private let barMappings: [BarBand]

    // True while an FFT is in flight on analysisQueue. Set on main before the
    // dispatch, cleared on analysisQueue the instant the FFT finishes -
    // deliberately NOT after the main-thread publish. A CADisplayLink tick is a
    // run-loop callback that can jump ahead of a main-queue block that is queued
    // but not yet drained, so gating on the publish made the next tick see the
    // analysis as still running and over-report overruns. Lock-guarded because
    // main (set) and analysisQueue (clear) both touch it.
    private let analysisInFlight = OSAllocatedUnfairLock(initialState: false)
    private var isAnalyzing: Bool { analysisInFlight.withLock { $0 } }
    private func setAnalyzing(_ value: Bool) { analysisInFlight.withLock { $0 = value } }
    // FFT + mel binning runs here, off the main thread, so a busy main thread
    // (SwiftUI layout, or the system under load) can't stall the analysis and
    // slow the display. Serial, so the single FFTBand is only ever touched by one
    // tick at a time; userInteractive because it feeds a real-time display.
    // update() gates it with analysisInFlight so ticks never pile up, publishing the
    // heights back on main.
    private let analysisQueue = DispatchQueue(label: "com.innersoft.macSpec.analysis", qos: .userInteractive)
    // The test-tone inputs behind the last refreshTestSpectrum(). update() re-runs
    // it whenever these move; cleared while live audio shows so re-entering test
    // mode always repaints. nil means "nothing analyzed since we left test mode".
    private struct TestInputs: Equatable { var frequency: Double; var dbFloor: Float }
    private var lastTestInputs: TestInputs?
    // Held for the object's lifetime to opt out of App Nap, which would otherwise
    // throttle and coalesce the display link once the app stops being frontmost.
    private var activityToken: NSObjectProtocol?
    // print() is synchronous main-thread I/O, so overrun logging is rate-limited.
    private var overrunCount = 0
    private var lastOverrunLog: CFAbsoluteTime = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "com.innersoft.macSpec.tap")
    private var pending = [Float]()

    private static var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // Handoff from the audio callback (audio rate) to the display link (display
    // rate); each only ever holds the most recent value.
    private let latestChunkLock = NSLock()
    private var latestAudioChunk: [Float]?
    // Longer rolling buffer, FFT only: it needs far more history than the
    // waveform chunk to resolve bass. Written only on tapQueue.
    private var fftWindowBuffer: [Float] = []
    private var latestFFTWindow: [Float]?

    init(configuration: Configuration) {
        self.configuration = configuration
        band = FFTBand(size: configuration.fftSize)
        frame = FrameData(samplesCount: configuration.samplesCount, barsCount: configuration.barsCount)
        barMappings = Processor.computeBarMappings(
            configuration: configuration,
            binWidth: configuration.sampleRate / Double(configuration.fftSize),
            maxBin: band.maxBin
        )

        // Opt out of App Nap so the display link keeps firing when the app is not
        // frontmost - App Nap would otherwise throttle and coalesce it. The link
        // itself is created and driven by the view layer (see DisplayLinkView).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Real-time spectrum display"
        )

        // Never in previews. Deferred off this runloop turn: init runs inside
        // SwiftUI's view construction, and starting must not publish from there.
        if !Processor.isRunningForPreviews {
            DispatchQueue.main.async { [weak self] in
                self?.startSampling()
            }
        }
    }

    // What one bar reads out of the spectrum. Band edges are interpolation taps
    // between adjacent bins, not rounded to whole bins, which keeps a bar's
    // reading continuous as its band changes width across the axis.
    private struct BarBand {
        let lowerBin: Int
        let lowerFraction: Float
        let upperBin: Int
        let upperFraction: Float
        // Whole bins strictly inside the band, nil once the band is narrower than
        // one bin gap - then the edge taps alone describe it.
        let innerBins: ClosedRange<Int>?
    }

    // Bar index -> the band it covers, spread evenly along the mel scale. Edges
    // are not forced to advance a bin per bar: doing so tiles the low bars 1:1
    // onto bins (a linear axis) and kinks the spacing.
    private static func computeBarMappings(configuration: Configuration, binWidth: Double, maxBin: Int) -> [BarBand] {
        let lowMel = configuration.mel(configuration.minFrequency)
        let melPerBar = (configuration.mel(configuration.maxFrequency) - lowMel) / Double(configuration.barsCount)
        // Clamped one short of maxBin because a tap reads the bin above it too.
        func tap(at edge: Double) -> (bin: Int, fraction: Float) {
            let bin = min(max(1, Int(edge.rounded(.down))), maxBin - 1)
            return (bin, min(max(Float(edge - Double(bin)), 0), 1))
        }
        return (0..<configuration.barsCount).map { bar in
            let lower = configuration.frequency(mel: lowMel + melPerBar * Double(bar)) / binWidth
            let upper = configuration.frequency(mel: lowMel + melPerBar * Double(bar + 1)) / binWidth
            let first = max(Int(lower.rounded(.down)) + 1, 1)
            let last = min(Int(upper.rounded(.up)) - 1, maxBin)
            let lowerTap = tap(at: lower)
            let upperTap = tap(at: upper)
            return BarBand(
                lowerBin: lowerTap.bin,
                lowerFraction: lowerTap.fraction,
                upperBin: upperTap.bin,
                upperFraction: upperTap.fraction,
                innerBins: first <= last ? first...last : nil
            )
        }
    }

    // Hann window sized to the real (non-padded) sample count, not the band size:
    // a full-length window on the boundary of a shorter buffer tapers the padding
    // instead of the signal.
    static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else { return [] }
        return (0..<length).map { n in
            0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(length - 1)))
        }
    }

    deinit {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        stopSampling()
    }

    func startSampling() {
        guard tapID == AudioObjectID(kAudioObjectUnknown) else { return }

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "macSpec system audio tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var osStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard osStatus == noErr else {
            print("AudioHardwareCreateProcessTap failed: \(osStatus)")
            return
        }

        // A private aggregate should die with its process, but a force-quit run
        // can leave ours registered under this fixed UID; creating a second one
        // then fails with 'nope'. Clear any leftover first.
        let aggregateUID = "com.innersoft.macSpec.tap"
        if let stale = aggregateDevice(uid: aggregateUID) {
            AudioHardwareDestroyAggregateDevice(stale)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "macSpec tap device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
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
            stopSampling()
            return
        }

        // Pin the aggregate at the fixed analysis rate; it resamples whatever the
        // output device runs at up to this. Abort if the hardware won't take it.
        var rate = Float64(configuration.sampleRate)
        osStatus = AudioObjectSetPropertyData(
            aggregateID, &Processor.sampleRateAddress, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &rate
        )
        guard osStatus == noErr else {
            print("Pinning sample rate \(configuration.sampleRate) failed: \(osStatus)")
            stopSampling()
            return
        }

        osStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, tapQueue) { [weak self] _, inInputData, _, _, _ in
            self?.processTap(bufferList: inInputData)
        }
        guard osStatus == noErr, let ioProcID else {
            print("AudioDeviceCreateIOProcIDWithBlock failed: \(osStatus)")
            stopSampling()
            return
        }

        osStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard osStatus == noErr else {
            print("AudioDeviceStart failed: \(osStatus)")
            stopSampling()
            return
        }
    }

    // Looks up an already-registered device by UID, so a leftover aggregate from
    // a previous run can be found and destroyed.
    private func aggregateDevice(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let osStatus = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID
            )
        }
        guard osStatus == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    func stopSampling() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
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
    }

    // Runs on tapQueue: downmix to mono and hand off the most recent chunk plus
    // the rolling FFT window.
    private func processTap(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let floatData = data.assumingMemoryBound(to: Float.self)
        let samplesCount = configuration.samplesCount

        var downmixed = [Float]()
        downmixed.reserveCapacity(frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += floatData[frame * channels + channel]
            }
            downmixed.append(sum / Float(channels))
        }

        pending.append(contentsOf: downmixed)
        // Only the most recent whole chunk is read, so take just that one.
        let wholeChunks = pending.count / samplesCount
        if wholeChunks > 0 {
            let end = wholeChunks * samplesCount
            let chunk = Array(pending[(end - samplesCount)..<end])
            pending.removeFirst(end)
            latestChunkLock.lock()
            latestAudioChunk = chunk
            latestChunkLock.unlock()
        }

        fftWindowBuffer.append(contentsOf: downmixed)
        if fftWindowBuffer.count > band.size {
            fftWindowBuffer.removeFirst(fftWindowBuffer.count - band.size)
        }
        latestChunkLock.lock()
        latestFFTWindow = fftWindowBuffer
        latestChunkLock.unlock()
    }

    // Static sine at testFrequency, phase 0, filling the whole window - no rolling
    // state, so a given testFrequency always yields the same spectrum.
    private func makeTestSignal() -> [Float] {
        let omega = 2 * .pi * configuration.testFrequency / configuration.sampleRate
        return (0..<band.size).map { Float(sin(Double($0) * omega)) }
    }

    // Runs only when testFrequency changes (slider or sweep), not per display tick.
    // Bars/peaks are written directly so the display snaps to the true spectrum.
    private func refreshTestSpectrum() {
        let dbFloor = configuration.dbFloor
        let signal = makeTestSignal()
        let samples = signal.prefix(configuration.samplesCount).map { CGFloat($0) }
        setAnalyzing(true)
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let heights = self.spectrum(of: signal, dbFloor: dbFloor)
            self.setAnalyzing(false)
            DispatchQueue.main.async {
                guard self.configuration.isTest else { return }
                self.frame.snap(samples: samples, heights: heights)
            }
        }
    }

    // Raw |X|^2 -> 0...1 bar height on a dB scale: dbFloor maps to 0, full-scale
    // to 1. This keeps quiet high-frequency content visible next to loud bass.
    private func magnitudeToHeight(_ magnitude: Float, referenceMagnitude: Float, dbFloor: Float) -> CGFloat {
        let db = 10 * log10(max(magnitude / referenceMagnitude, 1e-10))
        let clamped = min(max(db, dbFloor), 0)
        return CGFloat((clamped - dbFloor) / -dbFloor)
    }

    // Windows, transforms and mel-bins one buffer into barsCount heights. Pure:
    // both callers layer their own behaviour on top (audio eases, test snaps).
    private func spectrum(of fftSource: [Float], dbFloor: Float) -> [CGFloat] {
        band.analyze(fftSource)

        let magnitudes = band.magnitudes
        let referenceMagnitude = band.referenceMagnitude
        func edge(bin: Int, fraction: Float) -> Float {
            let low = magnitudes[bin]
            let high = magnitudes[bin + 1]
            return low + (high - low) * fraction
        }

        let barsCount = configuration.barsCount
        var heights = [CGFloat](repeating: 0, count: barsCount)
        for i in 0..<barsCount {
            let mapping = barMappings[i]
            // Loudest point anywhere in the band: both edges plus every whole bin.
            var magnitude = max(
                edge(bin: mapping.lowerBin, fraction: mapping.lowerFraction),
                edge(bin: mapping.upperBin, fraction: mapping.upperFraction)
            )
            if let innerBins = mapping.innerBins {
                for bin in innerBins {
                    magnitude = max(magnitude, magnitudes[bin])
                }
            }
            heights[i] = magnitudeToHeight(magnitude, referenceMagnitude: referenceMagnitude, dbFloor: dbFloor)
        }
        return heights
    }

    private func logOverrun() {
        overrunCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastOverrunLog >= 1.0 else { return }
        print("\(overrunCount) overrun(s) per second")
        overrunCount = 0
        lastOverrunLog = now
    }

    // Display tick. Only live audio needs per-frame work; the test tone is static,
    // re-analyzed here only when one of its inputs has moved since the last tick.
    func update() {
        guard !configuration.isTest else {
            if configuration.isAnimating {
                configuration.testFrequency = configuration.testFrequency > configuration.maxFrequency ? configuration.minFrequency : configuration.testFrequency + configuration.testSweepStep
            }
            // Re-analyze when a test-tone input has moved - slider, sweep or
            // dbFloor - or when the tone was just switched on (lastTestInputs is
            // nil, having been cleared while live audio was showing).
            let inputs = TestInputs(frequency: configuration.testFrequency, dbFloor: configuration.dbFloor)
            // Skip while an analysis is still in flight: the input is left
            // unrecorded so the next free tick picks up the latest frequency.
            if inputs != lastTestInputs && !isAnalyzing {
                lastTestInputs = inputs
                refreshTestSpectrum()
            }
            return
        }
        lastTestInputs = nil

        guard !isAnalyzing else {
            logOverrun()
            return
        }

        latestChunkLock.lock()
        let chunk = latestAudioChunk
        let fftWindow = latestFFTWindow
        latestAudioChunk = nil
        latestChunkLock.unlock()

        let samplesCount = configuration.samplesCount
        guard var captured = chunk else { return }
        if captured.count < samplesCount {
            captured += [Float](repeating: 0, count: samplesCount - captured.count)
        }
        let samples = captured.map { min(max(CGFloat($0), -1.0), 1.0) }
        // FFT reads the longer rolling buffer, falling back to the waveform chunk
        // only before it fills. Snapshot the config scalars here on main so the
        // background analysis never reads the @Published values off-thread.
        let fftSource = fftWindow ?? captured
        let dbFloor = configuration.dbFloor
        let barFrames = configuration.barFrames
        let peakFrames = Int(configuration.peakFrames)

        // Run the FFT off main, clear the flag the moment it finishes, then
        // publish on main. Clearing before the main hop keeps the next tick's
        // "still analyzing?" check honest even if the run loop hasn't drained the
        // publish yet; the serial queue already stops two FFTs overlapping.
        setAnalyzing(true)
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let heights = self.spectrum(of: fftSource, dbFloor: dbFloor)
            self.setAnalyzing(false)
            DispatchQueue.main.async {
                guard !self.configuration.isTest else { return }
                self.frame.ease(
                    samples: samples,
                    heights: heights,
                    barFrames: barFrames,
                    peakFrames: peakFrames
                )
            }
        }
    }
}
