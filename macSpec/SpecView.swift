//
//  SpecView.swift
//  macSpec
//
//  Created by Milko Daskalov on 28.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//
import SwiftUI

struct SpecView: View {
    @ObservedObject var frame: FrameData

    private let borderWidth: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            let bars = frame.bars
            let peaks = frame.peaks
            let barsCount = CGFloat(bars.count)
            let barGap = size.width / (barsCount + 1) / 10
            let gapsWidth = (barsCount + 1) * barGap
            let barWidth = (size.width - gapsWidth) / barsCount
            let barsHeight = size.height - 2 * barGap
            let xAdjust = barWidth + barGap
            let minBarHeight = 1.0
            var barPath = Path()
            var peakPath = Path()

            for bar in 0..<bars.count {
                let x = barGap + CGFloat(bar) * xAdjust
                let y = max(bars[bar] * barsHeight, minBarHeight)
                let yPeak = peaks[bar] * barsHeight

                barPath.addRect(CGRect(x: x, y: size.height - barGap - y, width: barWidth, height: y))

                if yPeak > y {
                    peakPath.move(to: CGPoint(x: x, y: size.height - barGap - yPeak))
                    peakPath.addLine(to: CGPoint(x: x + barWidth, y: size.height - barGap - yPeak))
                }
            }

            context.fill(barPath, with: .color(.yellow))
            context.stroke(peakPath, with: .color(.red), lineWidth: 1)
        }
        .padding(borderWidth)
        .background(.black)
        .border(Color(.specBorder), width: borderWidth)
    }
}

#Preview {
    @Previewable @State var frame = FrameData(samplesCount: 400, barsCount: 51)
    @Previewable @State var position = 0.5

    // A moving bell curve of bars with the peaks held a little above them, so
    // the preview exercises both paths SpecView draws without any live audio.
    func simulate(_ position: Double) {
        let barsCount = frame.bars.count
        let center = position * Double(barsCount - 1)
        let width = Double(barsCount) / 15
        let bars = (0..<barsCount).map { bar -> CGFloat in
            let distance = (Double(bar) - center) / width
            return CGFloat(exp(-distance * distance))
        }
        let peaks = bars.map { min($0 + 0.02, 1.0) }
        frame.publish(samples: [], bars: bars, peaks: peaks)
    }

    return VStack {
        Slider(value: $position, in: 0...1)
        SpecView(frame: frame)
    }
    .padding()
    .frame(width: 500, height: 470)
    .onChange(of: position, initial: true) { _, newValue in
        simulate(newValue)
    }
}
