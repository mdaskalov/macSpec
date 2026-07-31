//
//  ContentView.swift
//  macSpecSwiftUI
//
//  Created by Milko Daskalov on 21.12.24.
//

import SwiftUI
import AppKit
import QuartzCore

extension Double {
    var noFraction: String {
        self.formatted(.number.precision(.fractionLength(0)))
    }
    var withFraction: String {
        self.formatted(.number.precision(.fractionLength(0...2)))
    }
    var scaled: String {
        self < 1000 ? self.noFraction : (self / 1000).withFraction
    }
    var inMs: String {
        self.scaled.appending(self < 1000 ? " ms" :" s")
    }
    var inHz: String {
        self.scaled.appending(self < 1000 ? " Hz" :" kHz")
    }
}

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
                    .frame(maxHeight: 130)
                DisplaySettings(configuration: configuration)
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

private struct DisplaySettings: View {
    @ObservedObject var configuration: Configuration

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Grid(alignment: .leading) {
            GridRow {
                HStack {
                    Toggle("Test", isOn: $configuration.isTest)
                        .toggleStyle(.button)
                    Toggle(isOn: $configuration.isAnimating) {
                        Image(systemName: configuration.isAnimating ? "pause.fill" : "play.fill")
                            .imageScale(.small)
                            .padding(3)
                    }
                    .toggleStyle(.button)
                    .buttonBorderShape(.circle)
                    .disabled(!configuration.isTest)
                    .opacity(configuration.isTest ? 1 : 0)
                }
                Text(configuration.testFrequency.inHz)
                    .frame(width: 65, alignment: .trailing)
                    .opacity(configuration.isTest ? 1 : 0)
                Slider(value: $configuration.testFrequency, in: configuration.minFrequency...configuration.maxFrequency)
                    .opacity(configuration.isTest ? 1 : 0)
            }
            GridRow {
                Text("Floor:")
                Text("\(Double(configuration.dbFloor).withFraction) dB")
                    .frame(width: 65, alignment: .trailing)
                Slider(value: $configuration.dbFloor, in: -90...(-20))
            }
            GridRow {
                Text("Bar Decay:")
                Text(configuration.barDecayMs.inMs)
                    .frame(width: 65, alignment: .trailing)
                Slider(value: $configuration.barDecayMs, in: 0...1500)
            }
            GridRow {
                Text("Peak Hold")
                Text(configuration.peakHoldMs.inMs)
                    .frame(width: 65, alignment: .trailing)
                Slider(value: $configuration.peakHoldMs, in: 0...2000)
            }
        }
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
