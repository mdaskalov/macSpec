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
    
    @Environment(\.displayScale) private var displayScale

    private let borderWidth: CGFloat = 1
    private let insetWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let bars = frame.bars
            let peaks = frame.peaks
            let barsCount = CGFloat(bars.count)
            let barGap = size.width / barsCount / 10
            let gapsWidth = barsCount * barGap
            let barWidth = (size.width - gapsWidth) / barsCount
            let xAdjust = barWidth + barGap

            let minBarHeight = 1 / displayScale

            var barPath = Path()
            var peakPath = Path()

            let xOrigin = barGap / 2

            for bar in 0..<bars.count {
                let x = xOrigin + CGFloat(bar) * xAdjust
                let y = max(bars[bar] * size.height, minBarHeight)
                let yPeak = peaks[bar] * size.height

                barPath.addRect(CGRect(x: x, y: size.height - y, width: barWidth, height: y))

                if yPeak > y {
                    peakPath.move(to: CGPoint(x: x, y: size.height - yPeak))
                    peakPath.addLine(to: CGPoint(x: x + barWidth, y: size.height - yPeak))
                }
            }

            context.fill(barPath, with: .color(.yellow))
            context.stroke(peakPath, with: .color(.red), lineWidth: 1)
        }
        .padding(borderWidth + insetWidth)
        .background(.black)
        .border(Color(.darkGray), width: borderWidth)
    }
}

#Preview {
    @Previewable @State var data = SpecData()
    @Previewable @State var timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    VStack {
        Slider(value: $data.testPhase, in: 0...data.maxTestPhase)
        SpecView(frame: data.frame)
    }
    .padding()
    .frame(width: 500, height: 470)
    .onReceive(timer) { _ in
        data.update()
    }
}
