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
    // Frames each peak has been held; reset when a bar overtakes it or the hold
    // expires. Owned here because the peaks it governs live here.
    private var peakTime: [Int]

    init(samplesCount: Int, barsCount: Int) {
        samples = [CGFloat](repeating: 0.0, count: samplesCount)
        bars = [CGFloat](repeating: 0.0, count: barsCount)
        peaks = [CGFloat](repeating: 0.0, count: barsCount)
        peakTime = [Int](repeating: 0, count: barsCount)
    }

    // Bars snap straight up to a new peak, then fall toward a lower reading at a
    // constant rate: 1/barFrames per frame, so a full-height bar reaches zero in
    // exactly barFrames frames. Clamped so it never drops below the new reading.
    private static func adjustValue(current: CGFloat, new: CGFloat, barFrames: CGFloat) -> CGFloat {
        guard new < current, barFrames > 0 else { return new }
        return max(new, current - 1.0 / barFrames)
    }

    // Live path: ease bars toward the new heights and hold each peak for
    // peakFrames before it can fall.
    func ease(samples: [CGFloat], heights: [CGFloat], barFrames: CGFloat, peakFrames: Int) {
        var newBars = bars
        var newPeaks = peaks
        for i in newBars.indices {
            newBars[i] = FrameData.adjustValue(current: newBars[i], new: heights[i], barFrames: barFrames)
            peakTime[i] += 1
            if peakTime[i] > peakFrames || newBars[i] > newPeaks[i] {
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
            peakTime[i] = 0
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
