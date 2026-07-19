//
//  ContentView.swift
//  macSpecSwiftUI
//
//  Created by Milko Daskalov on 21.12.24.
//

import SwiftUI


struct AppView: View {
    @StateObject var data = SpecData()
    @State var delay = 0.0
    @State var peaks: CGFloat = 0

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
                WaveView(data: data)
                    .aspectRatio(1.6, contentMode: .fit)
                    .frame(maxHeight: 150)
                VStack(alignment: .leading) {
                    Picker("", selection: sourceBinding) {
                        Text("Audio").tag(Source.audio)
                        Text("Test").tag(Source.test)
                        Text("Generated").tag(Source.generated)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Slider(value: $data.testPhase, in: 0...data.maxTestPhase)
                        .disabled(data.source == .audio)
                }
                .frame(maxWidth: .infinity)
            }
            SpecView(data: data)
            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .task {
            data.startSampling()
        }
    }
}

#Preview {
    AppView()
}
