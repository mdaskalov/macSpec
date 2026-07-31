//
//  ContentView.swift
//  macSpecSwiftUI
//
//  Created by Milko Daskalov on 21.12.24.
//

import SwiftUI
import AppKit
import QuartzCore


struct AppView: View {
    // @State, not @StateObject: Processor publishes nothing, so this is lifetime
    // ownership only.
    @State private var processor: Processor

    // Reached through the processor rather than stored alongside it, and
    // deliberately unobserved.
    //
    // Unobserved because @StateObject/@ObservedObject subscribe to the whole
    // object: any slider or sweep step would invalidate this entire body and
    // rebuild WaveView, SpecView and DisplayLinkView with it. This body reads
    // only displayRefreshRate, a let that never changes, so it has no reason to
    // redraw at all - the two control views below observe the configuration and
    // absorb those updates themselves.
    //
    // Reached through the processor because @State's initial value is built on
    // every init while only the first one is kept. A stored property captured in
    // init() would therefore bind to a discarded Configuration if AppView is ever
    // reconstructed; going through the surviving Processor cannot drift.
    private var configuration: Configuration { processor.configuration }

    init() {
        _processor = State(initialValue: Processor(configuration: Configuration()))
    }

    var body: some View {
        VStack {
            HStack {
                WaveView(frame: processor.frame)
                    .aspectRatio(1.6, contentMode: .fit)
                    .frame(maxHeight: 150)
                VStack(alignment: .leading) {
                    TestToneControls(configuration: configuration)
                    DisplaySettings(configuration: configuration)
                }
                .frame(maxWidth: .infinity)
            }
            SpecView(frame: processor.frame)
            Spacer()
        }
        .padding()
        .frame(minWidth: 650, minHeight: 400)
        .background(DisplayLinkView(frameRate: configuration.displayRefreshRate, processor: processor))
    }
}

// The test tone row. While the sweep runs it is testFrequency that moves, once
// per tick, and both the slider position and the Hz readout have to follow it.
// Split out so that redraw lands here instead of on the whole window.
private struct TestToneControls: View {
    @ObservedObject var configuration: Configuration

    var body: some View {
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
                Slider(value: $configuration.testFrequency, in: configuration.minFrequency...configuration.maxFrequency)
                Text("\(configuration.testFrequency, format: .number.precision(.fractionLength(2))) Hz")
                    .lineLimit(1)
            }
            .opacity(configuration.isTest ? 1 : 0)
        }
    }
}

// The three tunables. Redraws while any of them is being dragged - and, because
// ObservableObject notifies per object rather than per property, also while the
// sweep runs. Still far cheaper than redrawing the window.
private struct DisplaySettings: View {
    @ObservedObject var configuration: Configuration

    private let columns = [GridItem(.fixed(130)), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading) {
            GridRow {
                Text("Floor: \(configuration.dbFloor, format: .number.precision(.fractionLength(1))) dB")
                Slider(value: $configuration.dbFloor, in: -90...(0))
            }
            GridRow {
                DurationText("Bar Decay", milliseconds: configuration.barDecayMs)
                Slider(value: $configuration.barDecayMs, in: 10...1000)
            }
            GridRow {
                DurationText("Peak Hold", milliseconds: configuration.peakHoldMs)
                Slider(value: $configuration.peakHoldMs, in: 0...2000)
            }
        }
    }
}

// Readout for millisecond sliders. Whole milliseconds while the value
// stays under a second, then seconds with at most two decimal
private struct DurationText: View {
    let label: String
    let milliseconds: Double

    init(_ label: String, milliseconds: Double) {
        self.label = label
        self.milliseconds = milliseconds
    }

    var body: some View {
        Text("\(label): \(formatted)")
            .lineLimit(1)
    }

    private var formatted: String {
        milliseconds < 1000
            ? "\(milliseconds.formatted(.number.precision(.fractionLength(0)))) ms"
            : "\((milliseconds / 1000).formatted(.number.precision(.fractionLength(0...2)))) s"
    }
}

// Drives a per-frame callback from the display's vsync via CADisplayLink instead
// of a free-running timer, so each update() lands in step with the compositor. On
// macOS the link is created from the NSView it lives in, which is why this is a
// view bridge: it follows the window across screens and stops firing when hidden.
private struct DisplayLinkView: NSViewRepresentable {
    var frameRate: Float
    var processor: Processor

    func makeNSView(context: Context) -> DisplayLinkNSView {
        DisplayLinkNSView(frameRate: frameRate, processor: processor)
    }

    func updateNSView(_ nsView: DisplayLinkNSView, context: Context) {
        // This runs on every AppView body pass, and during a test sweep that is
        // once per display tick. Only assign on a real change, so the rate the
        // link is already running at is not rewritten 120 times a second.
        if nsView.frameRate != frameRate {
            nsView.frameRate = frameRate
        }
    }
}

private final class DisplayLinkNSView: NSView {
    // CADisplayLink retains its target, so targeting the view directly would make
    // the link and the view own each other and deinit could never run. The proxy
    // takes that strong reference instead and points back weakly.
    private final class Proxy: NSObject {
        weak var view: DisplayLinkNSView?

        init(view: DisplayLinkNSView) {
            self.view = view
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            // let duration = link.targetTimestamp - link.timestamp
            // if duration > 0 { print("FPS: \(1.0 / duration)") }
            view.processor.update() // Drive update() from the display's vsync
        }
    }

    let processor: Processor
    var frameRate: Float {
        didSet { applyFrameRate() }
    }
    private var link: CADisplayLink?

    init(frameRate: Float, processor: Processor) {
        self.frameRate = frameRate
        self.processor = processor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The link belongs to the window the view lands in, so recreate it on every
    // move (a screen change or a reopen) and drop it when the view leaves the
    // hierarchy - a link with no window would just idle.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: Proxy(view: self), selector: #selector(Proxy.tick))
        self.link = link
        applyFrameRate()
        link.add(to: .main, forMode: .common)
    }

    // Pin the callback to a fixed rate. On a ProMotion panel this requests a
    // steady rate rather than the adaptive 48-120Hz, which keeps the tick fast
    // enough to pick up every audio chunk as it lands - the decay and hold are
    // timed off the audio, so a slower rate would only cost smoothness.
    private func applyFrameRate() {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: frameRate)
    }

    deinit {
        link?.invalidate()
    }
}

#Preview {
    AppView()
}
