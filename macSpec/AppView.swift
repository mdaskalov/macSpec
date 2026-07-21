//
//  ContentView.swift
//  macSpecSwiftUI
//
//  Created by Milko Daskalov on 21.12.24.
//

import SwiftUI


struct AppView: View {
    @StateObject var data = SpecData()

    private var sourceBinding: Binding<Source> {
        Binding(
            get: { data.source },
            set: { newValue in
                guard data.source != newValue else { return }
                DispatchQueue.main.async {
                    data.source = newValue
                }
            }
        )
    }

    var body: some View {
        VStack {
            HStack {
                WaveView(frame: data.frame)
                    .aspectRatio(1.6, contentMode: .fit)
                    .frame(maxHeight: 150)
                VStack(alignment: .leading) {
                    HStack {
                        Picker("", selection: sourceBinding) {
                            Text("Audio").tag(Source.audio)
                            Text("Generated").tag(Source.generated)
                            Text("Test").tag(Source.test)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        HStack {
                            Slider(value: $data.testPhase, in: 0...data.maxTestPhase)
                                .disabled(data.source == .audio)
                            Text("\(data.testFrequency ?? 0, format: .number.precision(.fractionLength(0))) Hz")
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                        .opacity(data.testFrequency == nil ? 0 : 1)
                        .disabled(data.testFrequency == nil)
                    }
                    HStack {
                        Text("Floor")
                        Slider(value: $data.dbFloor, in: -90...(0))
                    }
                    HStack {
                        Text("Bar Decay")
                        Slider(value: $data.barDelay, in: 0...0.3)
                    }
                    HStack {
                        Text("Peak Hold")
                        Slider(value: $data.peakDelay, in: 0...200)
                    }
                    Text(String(format: "floor: %.0f, barDecay: %.3f peakDelay: %d, SampleRate: %.1f kHz, %.1f Hz",
                                data.dbFloor, data.barDelay, data.peakDelay, (data.sampleRate ?? 0) / 1000, data.testFrequency ?? 0 ))
                }
                .frame(maxWidth: .infinity)
            }
            SpecView(frame: data.frame)
            Spacer()
        }
        .padding()
        .frame(minWidth: 650, minHeight: 400)
        .task {
            data.startSampling()
        }
    }
}

#Preview {
    AppView()
}
