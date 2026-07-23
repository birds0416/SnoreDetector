//
//  Waveform.swift
//  SnoreDetector
//
//  Waveform extraction from saved .m4a clips + the scrubber view.
//
//  Waveforms are computed lazily off the main thread the first time a row
//  appears, downsampled to a small number of peak bins, and cached in memory
//  so the History list stays fast.
//

import AVFoundation
import SwiftUI

// MARK: - Waveform data + cache

struct WaveformData {
    /// Peak amplitude per bin, normalized 0…1.
    let samples: [Float]
    let duration: TimeInterval
}

@MainActor
final class WaveformStore {
    static let shared = WaveformStore()
    private var cache: [URL: WaveformData] = [:]

    func waveform(for url: URL, bins: Int = 96) async -> WaveformData? {
        if let cached = cache[url] { return cached }
        let data = await Task.detached(priority: .utility) {
            Self.compute(url: url, bins: bins)
        }.value
        if let data { cache[url] = data }
        return data
    }

    /// Decodes the clip and reduces it to `bins` peak values.
    nonisolated private static func compute(url: URL, bins: Int) -> WaveformData? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        let duration = Double(totalFrames) / format.sampleRate
        let framesPerBin = max(1, totalFrames / bins)

        var peaks = [Float](repeating: 0, count: bins)
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            return nil
        }

        var frameIndex = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channel = buffer.floatChannelData?[0] else { break }
            for i in 0..<frameCount {
                let bin = min(bins - 1, (frameIndex + i) / framesPerBin)
                let value = abs(channel[i])
                if value > peaks[bin] { peaks[bin] = value }
            }
            frameIndex += frameCount
        }

        let maxPeak = max(peaks.max() ?? 0, 0.001)
        return WaveformData(samples: peaks.map { min(1, $0 / maxPeak) }, duration: duration)
    }
}

// MARK: - Scrubber view

/// Waveform bars with a draggable playhead. Drag anywhere to seek.
struct WaveformScrubber: View {
    let waveform: WaveformData?
    /// Playback progress, 0…1.
    let progress: Double
    /// Called with the new fraction (0…1) while the user drags.
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                bars(color: Color(.systemGray4))
                bars(color: .orange)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * clamped)
                    }
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange)
                    .frame(width: 3)
                    .offset(x: min(max(0, width * clamped - 1.5), width - 3))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onScrub(min(max(0, gesture.location.x / width), 1))
                    }
            )
        }
    }

    private func bars(color: Color) -> some View {
        Canvas { context, size in
            // Placeholder flat bars while the waveform loads.
            let samples = waveform?.samples ?? [Float](repeating: 0.08, count: 60)
            let count = samples.count
            guard count > 0 else { return }
            let barWidth = size.width / CGFloat(count)
            for (index, sample) in samples.enumerated() {
                let barHeight = max(2.5, CGFloat(sample) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * barWidth + barWidth * 0.15,
                    y: (size.height - barHeight) / 2,
                    width: barWidth * 0.7,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                    with: .color(color)
                )
            }
        }
    }
}
