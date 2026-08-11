# macSpec

Real-time Spectrum Analyzer for macOS using CoreAudio and AudioToolbox.

![ScreenShot](https://raw.github.com/mdaskalov/macSpec/master/macSpec/resources/screenshot-video.gif)

Samples the System-audio tap: captures the mix going to the default output device and computes single-precision complex discrete Fourier transform of the input from the time to the frequency domain.

The bars are spread over the mel scale and drawn against an adjustable dB floor, with configurable bar decay and peak hold.

Featuring waveform and peak visualisation and test mode with simulated sine wave.
