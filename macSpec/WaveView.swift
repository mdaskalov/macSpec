//
//  WaveView.swift
//  macSpec
//
//  Created by Milko Daskalov on 21.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//
import SwiftUI

struct WaveView: View {
    @ObservedObject var data: SpecData
    
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let height = size.height / 2
            let step = size.width / CGFloat(max(data.samples.count, 1))
            var x = 0.0
            for (index, value) in data.samples.enumerated() {
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: height - (value * height)))
                } else {
                    path.addLine(to: CGPoint(x: x, y: height - (value * height)))
                }
                x += step
            }
            context.stroke(path, with: .color(.white), lineWidth: 1)
        }
        .padding(1)
        .background(.black)
        .border(Color(.darkGray))
    }

}

#Preview {
    @Previewable @State var data = SpecData()
    VStack {
        Slider(value: $data.testPhase, in: 0...100)
        WaveView(data: data)
            .aspectRatio(1.6, contentMode: .fit)
            .frame(height: 150)
    }
    .padding()
}
