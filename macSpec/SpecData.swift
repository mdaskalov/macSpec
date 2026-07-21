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

    // The bars are spread evenly over the mel scale rather than over frequency
    // or over log frequency. Mel is the perceptual scale: near-linear below
    // the break frequency, logarithmic above it.
    //
    // That shape is what suits a single fixed-resolution FFT. Pure log spacing
    // magnifies the bottom of the spectrum, which is exactly where 23Hz bins
    // have nothing to show - a 50Hz tone would smear over 37 bars. Mel keeps
    // the bars roughly proportional to the bins instead (0.65 bins wide at
    // 20Hz rising to 18.7 at 20kHz, against 0.04 to 37.6 for pure log), so one
    // 2048-point window serves the whole axis.
    private static let minFrequency: Double = 20.0
    private static let maxFrequency: Double = 20_000.0
    // Where mel bends from linear to logarithmic, and so the one knob that
    // controls the look: lower it to give the bass more of the display (more
    // log-like), raise it for less.
    private static let melBreakFrequency: Double = 700.0
    private static let melScale: Double = 2595.0
    private static func mel(_ frequency: Double) -> Double {
        melScale * log10(1 + frequency / melBreakFrequency)
    }
    private static func frequency(mel: Double) -> Double {
        melBreakFrequency * (pow(10, mel / melScale) - 1)
    }

    // Used to lay the bars out until the tap reports its real rate.
    private static let defaultSampleRate: Double = 48_000.0

    // Free to choose: mel spacing keeps bar width tracking bin width, so this
    // is a display-density decision and nothing else depends on it. (It is
    // independent of samplesCount, which only sizes the waveform buffer.)
    let barsCount: Int = 160

    // Display tick rate: update() (and with it the bar decay and peak hold,
    // both counted in frames) runs this many times per second.
    let displayRefreshRate: Double = 60.0

    // @Published so that the readout next to the sliders re-renders as they
    // move. A plain var still drives the Slider (the binding writes it), but
    // nothing announces the change, so any Text showing the value keeps the
    // number it was first drawn with. Only AppView observes these - SpecView
    // watches `frame` alone - so this costs a control redraw during a drag and
    // nothing per audio frame.
    @Published var barDelay: CGFloat = 0.04
    @Published var peakDelay: CGFloat = 60.0
    // Unlike the other two this also changes the analysis, not just how the
    // next frame decays: it is the dB range the bars are drawn against. The
    // test tone is only analyzed when it changes, so moving this while it is
    // showing has to re-run that - otherwise the floor appears to do nothing
    // until the test slider is nudged.
    @Published var dbFloor: Float = -55.0 {
        didSet {
            guard source != .audio, dbFloor != oldValue else { return }
            refreshTestSpectrum()
        }
    }

    @Published private(set) var sampleRate: Double? {
        didSet {
            guard sampleRate != oldValue else { return }
            rebuildBarMappings()
        }
    }

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

    // One resolution for the whole display. 2048 is ~23Hz bins and a 43ms
    // window at 48kHz.
    //
    // Deliberately not paired with a longer window for the bass: a 8192-point
    // window resolves low notes far better, but it is 171ms of history whose
    // Hann weighting centres ~85ms in the past, against ~21ms for this one.
    // Bass bars then lag treble bars by ~64ms on screen, which reads as a
    // sluggish, oddly disconnected display - and no display refresh rate fixes
    // it, because window length, not frame rate, is what limits how fast a bar
    // can change.
    private let band = FFTBand(size: 2048)

    // Where each bar reads from. Maps Hz to bin indices, so it is rebuilt
    // whenever sampleRate changes.
    private var barMappings: [BarBand?]

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
        peakTime = [Int](repeating: 0, count: barsCount)
        // Laid out for the assumed rate; rebuilt when the tap reports its own.
        barMappings = SpecData.computeBarMappings(
            barsCount: barsCount,
            binWidth: SpecData.defaultSampleRate / Double(band.size),
            maxBin: band.maxBin
        )

        startDisplayTimer()
    }

    // What one bar reads out of the spectrum. Which case applies depends on
    // the bar's bandwidth relative to a bin, which grows with frequency.
    //
    // The band edges are interpolation taps between adjacent bins rather than
    // being rounded to whole bins, which is what keeps a bar's reading
    // continuous as its band changes width. Rounding gave the two regimes
    // different answers to the same question: a bar covering two whole bins
    // reported their peak, while a neighbour covering less than one bin
    // reported a *blend* of that same pair. Below ~330Hz, where the bands
    // hover around one bin wide, bars alternate between the two - so alternate
    // bars read low and punched a hole in the middle of a peak.
    private struct BarBand {
        // Lower and upper band edge, each as a bin index plus how far it lies
        // towards the next bin.
        let lowerBin: Int
        let lowerFraction: Float
        let upperBin: Int
        let upperFraction: Float
        // Whole bins strictly inside the band. Empty once the band is narrower
        // than the gap between two bins, at which point the edge taps alone
        // describe it - no special case needed.
        let innerBins: ClosedRange<Int>?
    }

    // Maps bar index -> the band it covers, spread evenly along the mel scale.
    // nil marks a bar above Nyquist for the current rate: kept as a bar rather
    // than dropped, so the axis stays a fixed 20Hz...20kHz whatever the rate.
    //
    // Note the edges are not forced to advance at least one bin per bar.
    // Forcing that makes the low bars tile bins 1,2,3... one-to-one, which is
    // a linear axis; the intended spacing then only takes effect above the
    // frequency where it overtakes the clamp, putting a kink in the axis with
    // everything below it linear. A symmetric leakage skirt then renders wide
    // on its low side and narrow on its high side.
    private static func computeBarMappings(barsCount: Int, binWidth: Double, maxBin: Int) -> [BarBand?] {
        let lowMel = mel(minFrequency)
        let melPerBar = (mel(maxFrequency) - lowMel) / Double(barsCount)
        // Clamped one short of maxBin because interpolating from a tap reads
        // the bin above it as well.
        func tap(at edge: Double) -> (bin: Int, fraction: Float) {
            let bin = min(max(1, Int(edge.rounded(.down))), maxBin - 1)
            return (bin, min(max(Float(edge - Double(bin)), 0), 1))
        }
        return (0..<barsCount).map { bar -> BarBand? in
            let lower = frequency(mel: lowMel + melPerBar * Double(bar)) / binWidth
            let upper = frequency(mel: lowMel + melPerBar * Double(bar + 1)) / binWidth
            guard lower <= Double(maxBin) else { return nil }
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

    // The bars are laid out in Hz, so a rate change moves every bar's bins.
    // Without this each bar would keep pointing at the frequency it meant
    // under the old rate.
    private func rebuildBarMappings() {
        barMappings = SpecData.computeBarMappings(
            barsCount: barsCount,
            binWidth: (sampleRate ?? SpecData.defaultSampleRate) / Double(band.size),
            maxBin: band.maxBin
        )
    }

    // A Hann window sized to the number of real (non-zero-padded) samples
    // being analyzed, not to the band's size - a full-length window landing on
    // the boundary between a shorter buffer and its zero padding tapers the
    // padding instead of the signal, which smears the spectrum.
    private static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: length) }
        return (0..<length).map { n in
            0.5 * (1 - cos(2 * Float.pi * Float(n) / Float(length - 1)))
        }
    }

    // Owns one FFT's setup, window and output magnitudes. Holding the window
    // here is what lets it be cached: it only needs rebuilding when the number
    // of real samples changes, which stops happening once the rolling buffer
    // has filled.
    private final class FFTBand {
        let size: Int
        // Highest bin holding a positive frequency (size/2 being Nyquist).
        let maxBin: Int
        private(set) var magnitudes: [Float]
        // The |X|^2 a full-scale, bin-aligned sine would produce for however
        // many real samples were windowed last call (Hann coherent gain is
        // ~0.5, so that peaks at count * 0.5 / 2).
        private(set) var referenceMagnitude: Float = 1

        private let length: vDSP_Length
        private let setup: FFTSetup?
        private var real: [Float]
        private var imag: [Float]
        // Rebuilt only when the number of real samples changes, which stops
        // happening once the rolling buffer has filled.
        private var window: [Float] = []

        init(size: Int) {
            self.size = size
            maxBin = size / 2
            length = vDSP_Length(log2(Double(size)))
            setup = vDSP_create_fftsetup(length, FFTRadix(kFFTRadix2))
            real = [Float](repeating: 0, count: size)
            imag = [Float](repeating: 0, count: size)
            magnitudes = [Float](repeating: 0, count: size)
        }

        deinit {
            if let setup {
                vDSP_destroy_fftsetup(setup)
            }
        }

        // Transforms the most recent `size` samples of source - its tail, not
        // its head, so that a source longer than one window still yields the
        // current audio rather than the oldest it happens to be holding.
        func analyze(_ source: [Float]) {
            let count = min(source.count, size)
            guard count > 0 else {
                for i in magnitudes.indices { magnitudes[i] = 0 }
                referenceMagnitude = 1
                return
            }
            if window.count != count {
                window = SpecData.hannWindow(length: count)
            }
            let start = source.count - count
            // vDSP rather than element-wise Swift loops: windowing and clearing
            // together touch three 2048-element buffers every frame, and
            // vDSP_fft_zip needs imag cleared each time because it transforms
            // in place. Clearing real unconditionally (rather than only its
            // zero-padded tail) costs one memset and saves a branch.
            vDSP_vclr(&real, 1, vDSP_Length(size))
            vDSP_vclr(&imag, 1, vDSP_Length(size))
            source.withUnsafeBufferPointer { sourcePtr in
                guard let sourceBase = sourcePtr.baseAddress else { return }
                vDSP_vmul(sourceBase + start, 1, window, 1, &real, 1, vDSP_Length(count))
            }
            referenceMagnitude = pow(Float(count) * 0.25, 2)

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    magnitudes.withUnsafeMutableBufferPointer { magPtr in
                        guard let realBase = realPtr.baseAddress,
                              let imagBase = imagPtr.baseAddress,
                              let magBase = magPtr.baseAddress,
                              let setup else { return }
                        var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        vDSP_fft_zip(setup, &splitComplex, 1, length, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, magBase, 1, vDSP_Length(size))
                    }
                }
            }
        }
    }

    deinit {
        displayTimer?.cancel()
        displayTimer = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        stopSampling()
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
        // Only ever the most recent whole chunk is read, so take just that one.
        // Looping a chunk at a time copied every older chunk in the buffer as
        // well, only to overwrite it on the next turn.
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

    // A static sine at testFrequency, always starting at phase 0 and filling
    // the whole FFT window - no rolling state, so the same testPhase always
    // yields exactly the same signal and the same spectrum.
    private func makeTestSignal() -> [Float] {
        let omega = testPhase / 64.0
        return (0..<band.size).map { Float(sin(Double($0) * omega)) }
    }

    // Runs only when testPhase changes (slider drag, or the .generated sweep),
    // not once per display tick. Bars/peaks are written directly instead of
    // being eased in, so the display settles immediately on the true spectrum
    // of the current tone.
    private func refreshTestSpectrum() {
        let signal = makeTestSignal()
        let samples = signal.prefix(samplesCount).map { CGFloat($0) }

        let heights = spectrum(of: signal)
        // Reset in place: the .generated sweep runs this every frame.
        for i in peakTime.indices {
            peakTime[i] = 0
        }

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

    // Windows, transforms and mel-bins one buffer into barsCount heights.
    // Pure: no smoothing, no peak state - both callers layer their own
    // behaviour on top (live audio eases, the test tone snaps).
    private func spectrum(of fftSource: [Float]) -> [CGFloat] {
        band.analyze(fftSource)

        let magnitudes = band.magnitudes
        let referenceMagnitude = band.referenceMagnitude
        // Reads the spectrum where the band edge actually falls, between bins.
        func edge(bin: Int, fraction: Float) -> Float {
            let low = magnitudes[bin]
            let high = magnitudes[bin + 1]
            return low + (high - low) * fraction
        }

        var heights = [CGFloat](repeating: 0, count: barsCount)
        for i in 0..<barsCount {
            var magnitude: Float = 0
            if let mapping = barMappings[i] {
                // The loudest point anywhere in the band: both edges, plus
                // every whole bin between them.
                magnitude = max(
                    edge(bin: mapping.lowerBin, fraction: mapping.lowerFraction),
                    edge(bin: mapping.upperBin, fraction: mapping.upperFraction)
                )
                if let innerBins = mapping.innerBins {
                    for bin in innerBins {
                        magnitude = max(magnitude, magnitudes[bin])
                    }
                }
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
        let holdFrames = Int(peakDelay)
        for i in 0..<barsCount {
            newBars[i] = adjustValue(current: newBars[i], new: heights[i])
            peakTime[i] += 1
            if peakTime[i] > holdFrames || newBars[i] > newPeaks[i] {
                peakTime[i] = 0
                newPeaks[i] = newBars[i]
            }
        }

        frame.publish(samples: samples, bars: newBars, peaks: newPeaks)
    }

}
