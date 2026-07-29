//
//  FrameData.swift
//  macSpec
//
//  Created by Milko Daskalov on 22.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import Foundation

// The frame the views draw: one waveform buffer plus the current bar and peak
// heights. Also doubles as the decay/peak-hold state - what it currently shows
// is exactly the input the next frame's easing needs.
final class FrameData: ObservableObject {
    private(set) var samples: [CGFloat]
    private(set) var bars: [CGFloat]
    private(set) var peaks: [CGFloat]
    // Milliseconds each peak has been held; reset when a bar overtakes it or the
    // hold expires. Owned here because the peaks it governs live here.
    private var peakTime: [Double]

    init(samplesCount: Int, barsCount: Int) {
        samples = [CGFloat](repeating: 0.0, count: samplesCount)
        bars = [CGFloat](repeating: 0.0, count: barsCount)
        peaks = [CGFloat](repeating: 0.0, count: barsCount)
        peakTime = [Double](repeating: 0.0, count: barsCount)
    }

    // Bars snap straight up to a new peak, then fall toward a lower reading at a
    // constant rate. `fall` is the drop this step is worth - elapsed time over
    // the full-height decay time - clamped so it never lands below the new reading.
    private static func adjustValue(current: CGFloat, new: CGFloat, fall: CGFloat) -> CGFloat {
        guard new < current else { return new }
        return max(new, current - fall)
    }

    // Live path: ease bars toward the new heights and hold each peak for
    // peakHold before it can fall. All three durations are milliseconds of
    // audio; `elapsed` is how much of it this call advances the display by, so
    // the fall and the hold keep their meaning whatever rate ease() is called at.
    func ease(samples: [CGFloat], heights: [CGFloat], elapsed: Double, barDecay: Double, peakHold: Double) {
        // A zero decay time means no easing at all: drop a full height in one step.
        let fall = barDecay > 0 ? CGFloat(elapsed / barDecay) : 1.0
        var newBars = bars
        var newPeaks = peaks
        for i in newBars.indices {
            newBars[i] = FrameData.adjustValue(current: newBars[i], new: heights[i], fall: fall)
            peakTime[i] += elapsed
            if peakTime[i] > peakHold || newBars[i] > newPeaks[i] {
                peakTime[i] = 0
                newPeaks[i] = newBars[i]
            }
        }
        publish(samples: samples, bars: newBars, peaks: newPeaks)
    }

    // Test path: snap bars and peaks straight to the true spectrum and clear the
    // peak hold, so the display shows it exactly with no easing.
    func snap(samples: [CGFloat], heights: [CGFloat]) {
        for i in peakTime.indices {
            peakTime[i] = 0.0
        }
        publish(samples: samples, bars: heights, peaks: heights)
    }

    func publish(samples: [CGFloat], bars: [CGFloat], peaks: [CGFloat]) {
        objectWillChange.send()
        self.samples = samples
        self.bars = bars
        self.peaks = peaks
    }
}
