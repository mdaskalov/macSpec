//
//  SpecView.swift
//  macSpec
//
//  Created by Milko Daskalov on 28.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//
import SwiftUI

struct SpecView: View {
    @StateObject var data: SpecData
    
    var body: some View {
        Canvas { context, size in
            let barsCount = CGFloat(data.bars.count)
            let barGap = size.width / barsCount / 10
            let gapsWidth = barsCount * barGap
            let barWidth = (size.width - gapsWidth) / barsCount
            let xAdjust = barWidth + barGap

            var barPath = Path()
            var peakPath = Path()
            
            for bar in 0..<data.bars.count {
                let x = barGap + CGFloat(bar) * xAdjust
                let y = data.bars[bar] * size.height
                let yPeak = data.peaks[bar] * size.height

                barPath.addRect(CGRect(x: x, y: size.height - y, width: barWidth, height: y))

                if yPeak > y {
                    peakPath.move(to: CGPoint(x: x, y: size.height - yPeak))
                    peakPath.addLine(to: CGPoint(x: x + barWidth, y: size.height - yPeak))
                }
            }

            context.fill(barPath, with: .color(.yellow))
            context.stroke(peakPath, with: .color(.red), lineWidth: 1)
        }
        .background(.black)
        .border(Color(.darkGray))
    }
}

#Preview {
    @Previewable @State var data = SpecData()
    @Previewable @State var timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    VStack {
        Slider(value: $data.testPhase, in: 0...data.maxTestPhase)
        SpecView(data: data)
    }
    .padding()
    .frame(width: 500, height: 470)
    .onReceive(timer) { _ in
        data.update(bufIndex: 0)
    }
}
