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
                            Slider(value: $configuration.testFrequency, in: configuration.minFrequency...configuration.maxFrequency)
                            Text("\(configuration.testFrequency, format: .number.precision(.fractionLength(2))) Hz")
                                .lineLimit(1)
                        }
                        .opacity(configuration.isTest ? 1 : 0)
                    }
                    let columns = [GridItem(.fixed(130)), GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading) {
                        GridRow {
                            Text("Floor: \(configuration.dbFloor, format: .number.precision(.fractionLength(1))) dB")
                            Slider(value: $configuration.dbFloor, in: -90...(0))
                        }
                        GridRow {
                            Text("Bar Decay: \(configuration.barDecayMs, format: .number.precision(.fractionLength(0))) ms")
                            Slider(value: $configuration.barDecayMs, in: 10...1000)
                        }
                        GridRow {
                            Text("Peak Hold: \(configuration.peakHoldMs, format: .number.precision(.fractionLength(0))) ms")
                            Slider(value: $configuration.peakHoldMs, in: 0...2000)
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
        // Drive update() from the display's vsync, pinned to displayRefreshRate.
        .background(DisplayLinkView(frameRate: configuration.displayRefreshRate) {
            processor.update()
        })
    }
}

// Drives a per-frame callback from the display's vsync via CADisplayLink instead
// of a free-running timer, so each update() lands in step with the compositor. On
// macOS the link is created from the NSView it lives in, which is why this is a
// view bridge: it follows the window across screens and stops firing when hidden.
struct DisplayLinkView: NSViewRepresentable {
    var frameRate: Double
    var onFrame: () -> Void

    func makeNSView(context: Context) -> DisplayLinkNSView {
        DisplayLinkNSView(frameRate: frameRate, onFrame: onFrame)
    }

    func updateNSView(_ nsView: DisplayLinkNSView, context: Context) {
        nsView.onFrame = onFrame
        nsView.frameRate = frameRate
    }
}

final class DisplayLinkNSView: NSView {
    // CADisplayLink retains its target, so targeting the view directly would make
    // the link and the view own each other and deinit could never run. The proxy
    // takes that strong reference instead and points back weakly.
    private final class Proxy: NSObject {
        weak var view: DisplayLinkNSView?

        init(view: DisplayLinkNSView) {
            self.view = view
        }

        @objc func tick(_ sender: CADisplayLink) {
            guard let view else {
                sender.invalidate()
                return
            }
            view.onFrame()
        }
    }

    var onFrame: () -> Void
    var frameRate: Double {
        didSet { applyFrameRate() }
    }
    private var link: CADisplayLink?

    init(frameRate: Double, onFrame: @escaping () -> Void) {
        self.frameRate = frameRate
        self.onFrame = onFrame
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
        let rate = Float(frameRate)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: rate)
    }

    deinit {
        link?.invalidate()
    }
}

#Preview {
    AppView()
}
