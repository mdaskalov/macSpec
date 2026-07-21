//
//  SpecData.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

enum Source: String, CaseIterable, Identifiable {
    case audio, test, generated
    var id: Self { self }
}

final class FrameData: ObservableObject {
    private(set) var samples: [CGFloat]
    private(set) var bars: [CGFloat]
    private(set) var peaks: [CGFloat]

    init(samplesCount: Int, barsCount: Int) {
        samples = [CGFloat](repeating: 0.0, count: samplesCount)
        bars = [CGFloat](repeating: 0.0, count: barsCount)
        peaks = [CGFloat](repeating: 0.0, count: barsCount)
    }

    func publish(samples: [CGFloat], bars: [CGFloat], peaks: [CGFloat]) {
        objectWillChange.send()
        self.samples = samples
        self.bars = bars
        self.peaks = peaks
    }
}

class SpecData: ObservableObject {
    let maxTestPhase: Double = 190.0
    let samplesCount: Int = 400
    let barsCount: Int = 160

    // Display tick rate: update() (and with it the bar decay and peak hold,
    // both counted in frames) runs this many times per second.
    let displayRefreshRate: Double = 60.0

    var barDelay: CGFloat = 0.05
    var peakDelay: CGFloat = 50.0
    var dbFloor: Float = -60.0

    @Published private(set) var sampleRate: Double?

    @Published var source: Source = .audio {
        didSet {
            testPhase = 0
        }
    }

    var testFrequency: Double? {
        guard source != .audio, let sampleRate else { return nil }
        return (testPhase / 64.0) * sampleRate / (2 * .pi)
    }

    @Published var testPhase: Double = 0.0 {
        didSet {
            guard source != .audio else { return }
            refreshTestSpectrum()
        }
    }

    // Also doubles as the decay/peak-hold state: what it currently shows is
    // exactly the input the next frame's easing needs.
    let frame: FrameData

    // The FFT transforms a fixed power-of-two window (independent of
    // samplesCount, which only sizes the waveform display buffer). This needs
    // to be large enough to resolve bass frequencies distinctly: bin width is
    // sampleRate/fftSize, so 2048 (~21.5Hz/bin) gives real low-end resolution.
    private let fftSize: Int = 2048
    private let fftLength: vDSP_Length
    private let fftSetup: FFTSetup?
    private var fftResult: [Float]

    // How far up the spectrum the last bar reaches, as a fraction of Nyquist
    // (sampleRate / 2, the highest frequency the FFT can resolve at all -
    // 24kHz at a 48kHz device rate, 22.05kHz at 44.1kHz). 1.0 shows
    // everything; lowering it trims the near-silent top end and spreads the
    // bars over the audible range instead.
    private let maxFrequencyRatio: Double = 0.85

    // Bars are spaced logarithmically over the FFT bins so the musically
    // busy low/mid range fills most of the display
    private let maxBin: Int
    private let barBinRanges: [ClosedRange<Int>]

    private var peakTime: [Int]

    private var inUpdate: Bool = false
    private var displayTimer: DispatchSourceTimer?
    // Held for the object's lifetime to opt out of App Nap. Without it macOS
    // throttles and coalesces this app's timers once it stops being frontmost
    // (or just sits idle for a while), which shows up as the spectrum
    // gradually updating slower and slower.
    private var activityToken: NSObjectProtocol?
    // Overrun logging is rate-limited: print() is synchronous I/O on the main
    // thread, so logging every dropped frame makes the drops worse.
    private var overrunCount: Int = 0
    private var lastOverrunLog: CFAbsoluteTime = 0

    // System-audio tap: captures the mix going to the default output device
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "com.innersoft.macSpec.tap")
    private var pending = [Float]()

    // The tap captures the default output device, so that device - not the
    // private aggregate we wrap it in - is the authority on the sample rate.
    // The aggregate reports its own nominal rate, which just sits at the
    // 48kHz default regardless of what the speakers are actually running at.
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // Handoff from the audio callback (runs at audio rate) to the display
    // timer (runs at display rate); only ever holds the most recent chunk.
    private let latestChunkLock = NSLock()
    private var latestAudioChunk: [Float]?

    // Longer, continuously-updated rolling buffer of raw mono samples, used
    // only for the FFT - it needs far more history than the waveform's chunk
    // to resolve bass frequencies distinctly. Written only on tapQueue.
    private var fftWindowBuffer: [Float] = []
    // Lock-protected handoff of the above, mirroring latestAudioChunk.
    private var latestFFTWindow: [Float]?

    init() {
        frame = FrameData(samplesCount: samplesCount, barsCount: barsCount)

        fftLength = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))
        fftResult = [Float](repeating: 0.0, count: fftSize)

        peakTime = [Int](repeating: 0, count: barsCount)

        let nyquistBin = fftSize / 2
        maxBin = max(1, Int(Double(nyquistBin) * maxFrequencyRatio))
        barBinRanges = SpecData.computeBarBinRanges(barsCount: barsCount, maxBin: maxBin)

        startDisplayTimer()
    }

    // Maps bar index -> a range of FFT bins, growing exponentially so low
    // bars each get their own bin (finest resolution the FFT allows) while
    // high bars aggregate a wide swath of high-frequency bins into one.
    private static func computeBarBinRanges(barsCount: Int, maxBin: Int) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        ranges.reserveCapacity(barsCount)
        var previousUpper = 0
        for bar in 0..<barsCount {
            let t = Double(bar + 1) / Double(barsCount)
            let raw = Int(pow(Double(maxBin), t).rounded())
            let upper = min(max(raw, previousUpper + 1), maxBin)
            let lower = previousUpper + 1
            ranges.append(lower...upper)
            previousUpper = upper
        }
        return ranges
    }

    // A Hann window sized to the number of real (non-zero-padded) samples
    // being analyzed, not to fftSize - a window shaped for 2048 samples
    // landing on the boundary between a shorter buffer and its zero padding
    // tapers the padding instead of the signal, which smears the spectrum.
    private static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: length) }
        return (0..<length).map { n in
            0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(length - 1)))
        }
    }

    deinit {
        displayTimer?.cancel()
        displayTimer = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        stopSampling()
        if let fft = fftSetup {
            vDSP_destroy_fftsetup(fft)
        }
    }

    func startSampling() {
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
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

        updateSampleRate()
        startSampleRateListeners()
    }

    // Whichever device the system is playing through, i.e. what the global
    // tap is capturing.
    private func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let osStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &SpecData.defaultOutputDeviceAddress,
            0, nil, &size, &deviceID
        )
        guard osStatus == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private func readSampleRate() -> Double? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let osStatus = AudioObjectGetPropertyData(
            deviceID, &SpecData.sampleRateAddress, 0, nil, &size, &rate
        )
        guard osStatus == noErr, rate > 0 else { return nil }
        return Double(rate)
    }

    // sampleRate is @Published, so the assignment has to land on main - the
    // listeners below fire on tapQueue.
    private func setSampleRate(_ rate: Double?) {
        if Thread.isMainThread {
            sampleRate = rate
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.sampleRate = rate
            }
        }
    }

    private func updateSampleRate() {
        setSampleRate(readSampleRate())
    }

    // The rate can change under us two different ways: the default output
    // device is switched, or the current one renegotiates (Audio MIDI Setup,
    // or differently-encoded content). Both need watching - a listener bound
    // to one device says nothing about the next one.
    private func startSampleRateListeners() {
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.bindSampleRateListener()
            self.updateSampleRate()
        }
        let osStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &SpecData.defaultOutputDeviceAddress,
            tapQueue, deviceListener
        )
        if osStatus == noErr {
            defaultDeviceListener = deviceListener
        } else {
            print("AudioObjectAddPropertyListenerBlock (default device) failed: \(osStatus)")
        }
        tapQueue.sync { bindSampleRateListener() }
    }

    // (Re)points the nominal-rate listener at the current default output
    // device. Runs on tapQueue, which owns this bookkeeping.
    private func bindSampleRateListener() {
        let deviceID = defaultOutputDevice() ?? AudioObjectID(kAudioObjectUnknown)
        guard deviceID != sampleRateListenerDevice else { return }
        unbindSampleRateListener()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.updateSampleRate()
        }
        let osStatus = AudioObjectAddPropertyListenerBlock(
            deviceID, &SpecData.sampleRateAddress, tapQueue, listener
        )
        guard osStatus == noErr else {
            print("AudioObjectAddPropertyListenerBlock (sample rate) failed: \(osStatus)")
            return
        }
        sampleRateListener = listener
        sampleRateListenerDevice = deviceID
    }

    private func unbindSampleRateListener() {
        if let sampleRateListener, sampleRateListenerDevice != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(
                sampleRateListenerDevice, &SpecData.sampleRateAddress, tapQueue, sampleRateListener
            )
        }
        sampleRateListener = nil
        sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    func stopSampling() {
        if let defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &SpecData.defaultOutputDeviceAddress,
                tapQueue, defaultDeviceListener
            )
            self.defaultDeviceListener = nil
        }
        tapQueue.sync { unbindSampleRateListener() }
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
        // Explicitly cleared: the output device still has a perfectly readable
        // rate once we stop, but it's no longer the rate of anything we show.
        setSampleRate(nil)
    }

    // Runs on tapQueue: downmix to mono and hand off full FFT-sized chunks
    private func processTap(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let floatData = data.assumingMemoryBound(to: Float.self)

        var downmixed = [Float]()
        downmixed.reserveCapacity(frames)
        for frame in 0..<frames {
            var sum: Float = 0.0
            for channel in 0..<channels {
                sum += floatData[frame * channels + channel]
            }
            downmixed.append(sum / Float(channels))
        }

        pending.append(contentsOf: downmixed)
        while pending.count >= samplesCount {
            let chunk = Array(pending.prefix(samplesCount))
            pending.removeFirst(samplesCount)
            latestChunkLock.lock()
            latestAudioChunk = chunk
            latestChunkLock.unlock()
        }

        fftWindowBuffer.append(contentsOf: downmixed)
        if fftWindowBuffer.count > fftSize {
            fftWindowBuffer.removeFirst(fftWindowBuffer.count - fftSize)
        }
        latestChunkLock.lock()
        latestFFTWindow = fftWindowBuffer
        latestChunkLock.unlock()
    }

    // A static sine at testFrequency, always starting at phase 0 and filling
    // the whole FFT window - no rolling state, so the same testPhase always
    // yields exactly the same signal and the same spectrum.
    private func makeTestSignal() -> [Float] {
        let omega = testPhase / 64.0
        return (0..<fftSize).map { Float(sin(Double($0) * omega)) }
    }

    // Runs only when testPhase changes (slider drag, or the .generated sweep),
    // not once per display tick. Bars/peaks are written directly instead of
    // being eased in, so the display settles immediately on the true spectrum
    // of the current tone.
    private func refreshTestSpectrum() {
        let signal = makeTestSignal()
        let samples = signal.prefix(samplesCount).map { CGFloat($0) }

        let heights = spectrum(of: signal)
        peakTime = [Int](repeating: 0, count: barsCount)

        frame.publish(samples: samples, bars: heights, peaks: heights)
    }

    // Drives update() at display rate, decoupled from the audio callback rate
    // (which can fire 100+ times/sec) and from the source picker.
    //
    // A DispatchSourceTimer rather than a run-loop Timer: run-loop timers carry
    // a default tolerance and get coalesced with other timers, so the effective
    // rate drifts downward the longer the app runs. This fires on the main
    // queue (drained in every run loop mode, so a Slider drag doesn't stall it)
    // with zero leeway.
    private func startDisplayTimer() {
        guard displayTimer == nil else { return }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Real-time spectrum display"
        )

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / displayRefreshRate, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.update()
        }
        timer.resume()
        displayTimer = timer
    }

    // Converts a raw |X|^2 bin magnitude to a 0...1 bar height on a dB scale:
    // dbFloor maps to 0, 0dB (full-scale) maps to 1. This is what makes quiet
    // high-frequency content visible next to loud bass instead of flattening
    // out under it, since both frequency and loudness perception are log, not linear.
    // referenceMagnitude is the |X|^2 a full-scale, bin-aligned sine would
    // produce for however many real samples were actually windowed this call
    // (Hann coherent gain is ~0.5, so that peaks at realCount * 0.5 / 2).
    private func magnitudeToHeight(_ magnitude: Float, referenceMagnitude: Float) -> CGFloat {
        let normalized = magnitude / referenceMagnitude
        let db = 10 * log10(max(normalized, 1e-10))
        let clamped = min(max(db, dbFloor), 0)
        return CGFloat((clamped - dbFloor) / -dbFloor)
    }

    func adjustValue(current: CGFloat, new: CGFloat) -> CGFloat {
        if new > current || current - barDelay < new {
            return new
        }
        return current - barDelay
    }

    // Windows, transforms and log-bins one buffer into barsCount heights.
    // Pure: no smoothing, no peak state - both callers layer their own
    // behaviour on top (live audio eases, the test tone snaps).
    private func spectrum(of fftSource: [Float]) -> [CGFloat] {
        let realCount = min(fftSource.count, fftSize)
        let window = SpecData.hannWindow(length: realCount)
        var fftInput = [Float](repeating: 0.0, count: fftSize)
        for i in 0..<realCount {
            fftInput[i] = fftSource[i] * window[i]
        }
        // Hann coherent gain is ~0.5, so a full-scale bin peaks at realCount * 0.5 / 2.
        let referenceMagnitude = pow(Float(realCount) * 0.25, 2)

        var imag = [Float](repeating: 0.0, count: fftSize)
        fftInput.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                if let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress {
                    var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    if let fft = fftSetup {
                        vDSP_fft_zip(fft, &splitComplex, 1, fftLength, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, &fftResult, 1, vDSP_Length(fftSize))
                    }
                }
            }
        }

        var heights = [CGFloat](repeating: 0, count: barsCount)
        for i in 0..<barsCount {
            var magnitude: Float = 0
            for bin in barBinRanges[i] {
                magnitude = max(magnitude, fftResult[bin])
            }
            heights[i] = magnitudeToHeight(magnitude, referenceMagnitude: referenceMagnitude)
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

    // Display tick. Only live audio needs per-frame work: the test tone is
    // static, so nothing is recomputed for it here - .generated just walks
    // testPhase, whose didSet does the (single) re-analysis.
    func update() {
        guard source == .audio else {
            if source == .generated {
                testPhase = testPhase > maxTestPhase ? 0.0 : testPhase + 0.01
            }
            return
        }

        guard !inUpdate else {
            logOverrun()
            return
        }
        inUpdate = true
        defer { inUpdate = false }

        latestChunkLock.lock()
        let chunk = latestAudioChunk
        let fftWindow = latestFFTWindow
        latestAudioChunk = nil
        latestChunkLock.unlock()

        guard var captured = chunk else { return }
        if captured.count < samplesCount {
            captured += [Float](repeating: 0.0, count: samplesCount - captured.count)
        }
        let samples = captured.map { min(max(CGFloat($0), -1.0), 1.0) }

        // The FFT reads the longer rolling buffer (falling back to the
        // waveform chunk only in the brief window before it fills up),
        // since it needs far more samples than the waveform's 400-sample
        // chunk to resolve bass frequencies.
        let heights = spectrum(of: fftWindow ?? captured)

        var newBars = frame.bars
        var newPeaks = frame.peaks
        for i in 0..<barsCount {
            newBars[i] = adjustValue(current: newBars[i], new: heights[i])
            peakTime[i] += 1
            if peakTime[i] > Int(peakDelay) || newBars[i] > newPeaks[i] {
                peakTime[i] = 0
                newPeaks[i] = newBars[i]
            }
        }

        frame.publish(samples: samples, bars: newBars, peaks: newPeaks)
    }

}
