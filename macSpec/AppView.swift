//
//  ContentView.swift
//  macSpecSwiftUI
//
//  Created by Milko Daskalov on 21.12.24.
//

import SwiftUI


struct AppView: View {
    @StateObject private var configuration: Configuration
    @StateObject private var processor: Processor

    init() {
        let configuration = Configuration()
        _configuration = StateObject(wrappedValue: configuration)
        _processor = StateObject(wrappedValue: Processor(configuration: configuration))
    }

    var body: some View {
        VStack {
            HStack {
                WaveView(frame: processor.frame)
                    .aspectRatio(1.6, contentMode: .fit)
                    .frame(maxHeight: 150)
                VStack(alignment: .leading) {
                    HStack {
                        Toggle("Test", isOn: $configuration.isTest)
                            .toggleStyle(.button)

                        HStack {
                            Toggle(isOn: $configuration.isAnimating) {
                                Image(systemName: configuration.isAnimating ? "pause.fill" : "play.fill")
                                    .imageScale(.small)
                                    .padding(3)
                            }
                            .toggleStyle(.button)
                            .buttonBorderShape(.circle)
                            .disabled(!configuration.isTest)
                            Slider(value: $configuration.testPhase, in: 0...configuration.maxTestPhase)
                            Text("\(configuration.testFrequency, format: .number.precision(.fractionLength(1))) Hz")
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                        .opacity(configuration.isTest ? 1 : 0)
                    }
                    Grid(alignment: .leading) {
                        GridRow {
                            Text("Floor")
                            Slider(value: $configuration.dbFloor, in: -90...(0))
                            Text("\(configuration.dbFloor, format: .number.precision(.fractionLength(1))) dB")
                                .gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Text("Bar Decay")
                            Slider(value: $configuration.barFrames, in: 1...120)
                            Text("\(configuration.barFrames, format: .number.precision(.fractionLength(0)))")
                        }
                        GridRow {
                            Text("Peak Hold")
                            Slider(value: $configuration.peakFrames, in: 0...200)
                            Text("\(configuration.peakFrames, format: .number.precision(.fractionLength(0)))")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            SpecView(frame: processor.frame)
            Spacer()
        }
        .padding()
        .frame(minWidth: 650, minHeight: 400)
    }
}

#Preview {
    AppView()
}
