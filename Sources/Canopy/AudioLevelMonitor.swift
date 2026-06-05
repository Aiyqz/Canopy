import Foundation
import ScreenCaptureKit
import CoreMedia
import Accelerate

/// Real-time audio spectrum analyzer fed by ScreenCaptureKit system-audio
/// capture. Confined to the capture sample queue (no locking needed).
final class AudioAnalyzer {
    let bandCount: Int
    private let fftSize = 1024
    private let half: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hann: [Float]
    private var ring: [Float]
    private var ringCount = 0

    // Scratch buffers reused across windows.
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]

    init(bandCount: Int) {
        self.bandCount = bandCount
        half = fftSize / 2
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        mags = [Float](repeating: 0, count: half)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Pulls mono samples out of a capture buffer and returns fresh band energies
    /// once a full FFT window has accumulated.
    func consume(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let firstBuffer = buffers.first, let data = firstBuffer.mData else { return nil }

        let floatCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }
        let ptr = data.bindMemory(to: Float.self, capacity: floatCount)

        var result: [Float]?
        if nonInterleaved || channels == 1 {
            // buffers[0] is a single channel already.
            result = append(UnsafeBufferPointer(start: ptr, count: floatCount))
        } else {
            // Interleaved: pull channel 0 (stride by channel count).
            var mono = [Float](); mono.reserveCapacity(floatCount / channels)
            var i = 0
            while i < floatCount { mono.append(ptr[i]); i += channels }
            result = mono.withUnsafeBufferPointer { append($0) }
        }
        return result
    }

    private func append(_ samples: UnsafeBufferPointer<Float>) -> [Float]? {
        var result: [Float]?
        var idx = 0
        while idx < samples.count {
            let n = min(fftSize - ringCount, samples.count - idx)
            for k in 0..<n { ring[ringCount + k] = samples[idx + k] }
            ringCount += n
            idx += n
            if ringCount == fftSize {
                result = analyze()
                ringCount = 0
            }
        }
        return result
    }

    private func analyze() -> [Float] {
        vDSP_vmul(ring, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Aggregate magnitude-squared bins into log-spaced bands (skip DC).
        var bands = [Float](repeating: 0, count: bandCount)
        let minBin = 1, maxBin = half - 1
        for b in 0..<bandCount {
            let lo = bin(for: b, minBin: minBin, maxBin: maxBin)
            let hi = max(lo + 1, bin(for: b + 1, minBin: minBin, maxBin: maxBin))
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            bands[b] = sqrtf(sum / Float(hi - lo))
        }
        return bands
    }

    private func bin(for index: Int, minBin: Int, maxBin: Int) -> Int {
        let t = Double(index) / Double(bandCount)
        let value = exp(log(Double(minBin)) + t * (log(Double(maxBin)) - log(Double(minBin))))
        return min(maxBin, max(minBin, Int(value)))
    }
}

/// Publishes normalized 0…1 audio levels per band for the EQ bars, capturing
/// system audio only while something is playing. Requires Screen Recording
/// permission (ScreenCaptureKit); falls back silently when unavailable.
@MainActor
final class AudioLevelMonitor: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    static let shared = AudioLevelMonitor()

    let bandCount = 4
    @Published private(set) var levels: [CGFloat] = []
    @Published private(set) var permissionDenied = false

    // Touched only from `sampleQueue` (the SCStreamOutput callback), never main.
    private nonisolated(unsafe) let analyzer: AudioAnalyzer
    private let sampleQueue = DispatchQueue(label: "pro.getcanopy.audio.capture")
    private var stream: SCStream?
    private var enabled = false
    private var starting = false

    // Display smoothing + auto-gain.
    private var peak: Float = 1e-4
    private var display: [Float]

    private override init() {
        analyzer = AudioAnalyzer(bandCount: 4)
        display = [Float](repeating: 0, count: 4)
        super.init()
    }

    /// Start/stop capture to match playback (idempotent).
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            Task { await startCapture() }
        } else {
            stopCapture()
        }
    }

    private func startCapture() async {
        guard stream == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Minimal video — we only want the audio tap.
            config.width = 160
            config.height = 90
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
            self.permissionDenied = false
        } catch {
            NSLog("Canopy: audio capture unavailable (\(error.localizedDescription)); EQ bars fall back to animation")
            self.permissionDenied = true
            self.stream = nil
        }
    }

    private func stopCapture() {
        let current = stream
        stream = nil
        levels = []
        display = [Float](repeating: 0, count: bandCount)
        peak = 1e-4
        guard let current else { return }
        Task {
            try? await current.stopCapture()
        }
    }

    // SCStreamOutput — called on `sampleQueue`.
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let bands = analyzer.consume(sampleBuffer) else { return }
        Task { @MainActor in self.publish(bands) }
    }

    // SCStreamDelegate
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            if self.enabled { await self.startCapture() } // transient drop — retry
        }
    }

    private func publish(_ raw: [Float]) {
        guard raw.count == bandCount else { return }
        let maxEnergy = raw.max() ?? 0
        // Auto-gain: track the recent peak with slow decay so bars use the full
        // range regardless of overall loudness.
        peak = Swift.max(peak * 0.995, maxEnergy, 1e-4)
        for i in 0..<bandCount {
            let norm = Swift.min(1, raw[i] / peak)
            // Fast attack, slow release for a natural EQ feel.
            display[i] = norm > display[i] ? norm : display[i] * 0.82 + norm * 0.18
        }
        levels = display.map { CGFloat($0) }
    }
}
