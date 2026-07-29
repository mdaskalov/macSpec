//
//  Configuration.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation

// Every constant and tunable parameter the display is built from. The processor
// reads what it needs from here; the views bind the sliders to the @Published
// values.
final class Configuration: ObservableObject {
    let samplesCount: Int = 400

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
    let fftSize: Int = 2048

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
    let minFrequency: Double = 0.0
    let maxFrequency: Double = 20_000.0
    // Where mel bends from linear to logarithmic, and so the one knob that
    // controls the look: lower it to give the bass more of the display (more
    // log-like), raise it for less.
    let melBreakFrequency: Double = 700.0
    let melScale: Double = 2595.0
    func mel(_ frequency: Double) -> Double {
        melScale * log10(1 + frequency / melBreakFrequency)
    }
    func frequency(mel: Double) -> Double {
        melBreakFrequency * (pow(10, mel / melScale) - 1)
    }

    // Fixed analysis rate. The processor pins the capture aggregate here at
    // startup (it resamples the output device up to it), so the bar layout,
    // Nyquist and test-tone frequency stay constant whatever the speakers run
    // at. 48kHz pairs with the 2048-point window for ~23Hz bins.
    let sampleRate: Double = 48_000.0

    // Free to choose: mel spacing keeps bar width tracking bin width, so this
    // is a display-density decision and nothing else depends on it. (It is
    // independent of samplesCount, which only sizes the waveform buffer.)
    let barsCount: Int = 160

    // Display tick rate: the CADisplayLink driving update() is pinned to this, so
    // the bar decay and peak hold (both counted in frames) run this many times a
    // second. 60 keeps those frame counts calibrated to real time; pinning also
    // stops a ProMotion panel drifting update() around a variable 48-120Hz.
    let displayRefreshRate: Double = 120.0

    // @Published so that the readout next to the sliders re-renders as they
    // move. A plain var still drives the Slider (the binding writes it), but
    // nothing announces the change, so any Text showing the value keeps the
    // number it was first drawn with. Only AppView observes these - SpecView
    // watches `frame` alone - so this costs a control redraw during a drag and
    // nothing per audio frame.
    // Both are counted in display frames. barFrames is how long a full-height
    // bar takes to fall to zero: it drops at a constant 1/barFrames per frame,
    // so 60 frames is a one-second fall at a 60Hz display rate. peakFrames is
    // how long a peak marker is held before it starts following the bar down.
    @Published var barFrames: CGFloat = 12.0
    @Published var peakFrames: CGFloat = 60.0
    // Unlike the other two this also changes the analysis, not just how the
    // next frame decays: it is the dB range the bars are drawn against. While
    // the test tone shows, the processor re-analyzes it when this moves so the
    // floor takes effect immediately rather than at the next test-slider nudge.
    @Published var dbFloor: Float = -50.0

    // Swaps the live audio spectrum for a static test tone. Turning it off
    // just stops any running sweep - testFrequency is left where it is, so the
    // tone's frequency stays on the readout as a reference to line up against
    // the peaks of the live audio.
    @Published var isTest: Bool = false {
        didSet {
            // Turning the tone off stops any running sweep; the processor's next
            // tick then paints the tone on, or hands back to live audio off.
            if !isTest { isAnimating = false }
        }
    }

    // Walks testFrequency across the range, sweeping the test tone. Only
    // meaningful while isTest is on.
    @Published var isAnimating: Bool = false

    // The frequency the tone sits at, in Hz. The slider binds to it directly and
    // the processor builds the sine straight from it; kept whether or not the
    // tone is showing so it can be read off while comparing against live audio.
    @Published var testFrequency: Double = 0.0

    // Per display tick the sweep advances the tone by this, wrapping at
    // maxFrequency. 1.2Hz at 60fps is ~72Hz/s - a full-range sweep in ~4.5min.
    let testSweepStep: Double = 1.2
}
