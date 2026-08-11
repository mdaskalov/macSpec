//
//  WaveView.swift
//  macSpec
//
//  Created by Milko Daskalov on 21.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//
import SwiftUI

struct WaveView: View {
    @ObservedObject var frame: FrameData

    private let lineWidth = 0.7
    private let borderWidth = 1.0

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let height = size.height / 2
            let step = size.width / CGFloat(frame.samples.count)
            var x = 0.0
            for (index, value) in frame.samples.enumerated() {
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: height - (value * height)))
                } else {
                    path.addLine(to: CGPoint(x: x, y: height - (value * height)))
                }
                x += step
            }
            context.stroke(path, with: .color(.white), lineWidth: lineWidth)
        }
        .padding(borderWidth)
        .background(.black)
        .border(Color(.specBorder), width: borderWidth)
    }

}

#Preview {
    @Previewable @State var frame = FrameData(samplesCount: 400, barsCount: 60)
    @Previewable @State var frequency = 0.5

    // A sine filling the sample buffer whose frequency the slider drives, so
    // the preview exercises WaveView without any live audio.
    func simulate(_ frequency: Double) {
        let samplesCount = frame.samples.count
        let cycles = frequency * 20
        let omega = 2 * Double.pi * cycles / Double(samplesCount)
        let samples = (0..<samplesCount).map { CGFloat(sin(Double($0) * omega)) }
        frame.publish(samples: samples, bars: [], peaks: [])
    }

    return VStack {
        Slider(value: $frequency, in: 0...1)
        WaveView(frame: frame)
            .aspectRatio(1.6, contentMode: .fit)
            .frame(height: 150)
    }
    .padding()
    .onChange(of: frequency, initial: true) { _, newValue in
        simulate(newValue)
    }
}
