//
//  AnalysisView.swift
//  SnoreDetector
//
//  M6 — correlates snoring with Apple Health sleep stages for a night:
//  combined timeline (sleep-stage lanes + snore overlays), per-stage stats,
//  snoring-minutes-per-stage bar chart, and tap-to-play snore clips.
//
//  Snore events that span a stage boundary are split proportionally between
//  the stages they overlap.
//

import Charts
import SwiftData
import SwiftUI

// MARK: - Per-stage statistics

struct StageStats: Identifiable {
    let stage: SleepStage
    var stageDuration: TimeInterval = 0
    var snoreDuration: TimeInterval = 0
    var confidenceWeighted: Double = 0 // sum of (peakConfidence × overlap seconds)

    var id: String { stage.rawValue }

    var snorePercent: Double {
        stageDuration > 0 ? snoreDuration / stageDuration * 100 : 0
    }

    var averageConfidence: Double? {
        snoreDuration > 0 ? confidenceWeighted / snoreDuration : nil
    }
}

enum SleepAnalysis {
    /// Splits every snore event's duration proportionally across the sleep
    /// stages it overlaps, and totals stage time within the session.
    static func stats(samples: [SleepStageSample], events: [SnoreEvent],
                      session interval: DateInterval) -> [StageStats] {
        var byStage: [SleepStage: StageStats] =
            Dictionary(uniqueKeysWithValues: SleepStage.allCases.map { ($0, StageStats(stage: $0)) })

        for sample in samples {
            byStage[sample.stage]?.stageDuration += sample.overlap(with: interval)
        }
        for event in events {
            let eventInterval = DateInterval(start: event.startDate, end: max(event.endDate, event.startDate))
            for sample in samples {
                let overlap = sample.overlap(with: eventInterval)
                guard overlap > 0 else { continue }
                byStage[sample.stage]?.snoreDuration += overlap
                byStage[sample.stage]?.confidenceWeighted += event.peakConfidence * overlap
            }
        }
        return SleepStage.allCases.compactMap { byStage[$0] }.filter { $0.stageDuration > 0 }
    }

    /// The stage a snore event mostly happened in.
    static func dominantStage(for event: SnoreEvent, samples: [SleepStageSample]) -> SleepStage? {
        let eventInterval = DateInterval(start: event.startDate, end: max(event.endDate, event.startDate))
        var durations: [SleepStage: TimeInterval] = [:]
        for sample in samples {
            let overlap = sample.overlap(with: eventInterval)
            if overlap > 0 { durations[sample.stage, default: 0] += overlap }
        }
        return durations.max { $0.value < $1.value }?.key
    }
}

// MARK: - Analysis view

struct AnalysisView: View {
    @Environment(HealthKitManager.self) private var healthKit
    @Environment(SnoreDetectionEngine.self) private var engine
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var selectedSessionID: UUID?
    @State private var samples: [SleepStageSample]?  // nil = loading
    @State private var selectedEventID: PersistentIdentifier?
    @State private var player = ClipPlayer()

    private var selectedSession: SleepSession? {
        sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if !HealthKitManager.isAvailable {
                    ContentUnavailableView(
                        "Health not available",
                        systemImage: "heart.slash",
                        description: Text("Apple Health is not available on this device.")
                    )
                } else if !healthKit.isEnabled {
                    ContentUnavailableView {
                        Label("Health access is off", systemImage: "heart.text.square")
                    } description: {
                        Text("Enable Apple Health sleep data in Settings to correlate snoring with your sleep stages.")
                    }
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "moon.zzz",
                        description: Text("Record a night on the Record tab first.")
                    )
                } else {
                    analysisContent
                }
            }
            .navigationTitle("Analysis")
            .onDisappear { player.stop() }
        }
    }

    // MARK: - Main content

    private var analysisContent: some View {
        List {
            Section {
                Picker("Night", selection: Binding(
                    get: { selectedSession?.id ?? sessions.first?.id },
                    set: { selectedSessionID = $0 }
                )) {
                    ForEach(sessions) { session in
                        Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                            .tag(Optional(session.id))
                    }
                }
            }

            if let session = selectedSession {
                if let samples {
                    if samples.isEmpty {
                        noSleepDataSection(for: session)
                    } else {
                        combinedSections(session: session, samples: samples)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Reading Apple Health…")
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                }
            }
        }
        .task(id: selectedSession?.id) {
            await loadSamples()
        }
    }

    private func loadSamples() async {
        guard let session = selectedSession else { return }
        samples = nil
        let end = session.endDate ?? Date()
        samples = await healthKit.sleepSamples(for: session.id, start: session.startDate, end: end)
    }

    // MARK: - Empty state (no Watch / no sleep data for this night)

    private func noSleepDataSection(for session: SleepSession) -> some View {
        Group {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "applewatch.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No sleep stage data for this night")
                        .font(.headline)
                    Text("Sleep stages usually come from an Apple Watch worn during sleep. Snoring data for this session is shown below on its own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            eventListSection(session: session, samples: [])
        }
    }

    // MARK: - Combined timeline + stats

    private func combinedSections(session: SleepSession, samples: [SleepStageSample]) -> some View {
        let interval = DateInterval(start: session.startDate, end: session.endDate ?? Date())
        let stats = SleepAnalysis.stats(samples: samples, events: session.events, session: interval)
        return Group {
            Section("Night timeline") {
                SleepTimelineView(
                    samples: samples,
                    events: session.events.sorted { $0.startDate < $1.startDate },
                    interval: timelineInterval(session: session, samples: samples),
                    selectedEventID: $selectedEventID
                )
                .frame(height: 190)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 18, trailing: 12))

                HStack(spacing: 14) {
                    ForEach(SleepStage.allCases) { stage in
                        HStack(spacing: 4) {
                            Circle().fill(stage.color).frame(width: 8, height: 8)
                            Text(stage.rawValue).font(.caption2)
                        }
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(.orange.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text("Snoring").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section("Snoring by sleep stage") {
                Chart(stats) { stat in
                    BarMark(
                        x: .value("Stage", stat.stage.rawValue),
                        y: .value("Snoring (min)", stat.snoreDuration / 60)
                    )
                    .foregroundStyle(stat.stage.color)
                    .annotation(position: .top) {
                        if stat.snoreDuration > 0 {
                            Text(minuteString(stat.snoreDuration))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYAxisLabel("min")
                .frame(height: 170)
                .padding(.vertical, 6)

                ForEach(stats) { stat in
                    HStack {
                        Circle().fill(stat.stage.color).frame(width: 10, height: 10)
                        Text(stat.stage.rawValue)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(minuteString(stat.snoreDuration)) of \(minuteString(stat.stageDuration)) · \(String(format: "%.1f%%", stat.snorePercent))")
                                .font(.subheadline.monospacedDigit())
                            if let conf = stat.averageConfidence {
                                Text("avg intensity \(String(format: "%.0f%%", conf * 100))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            eventListSection(session: session, samples: samples)
        }
    }

    /// Timeline spans the union of the session and all sleep samples.
    private func timelineInterval(session: SleepSession, samples: [SleepStageSample]) -> DateInterval {
        var start = session.startDate
        var end = session.endDate ?? Date()
        for sample in samples {
            start = min(start, sample.start)
            end = max(end, sample.end)
        }
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
    }

    // MARK: - Snore event list with playback

    private func eventListSection(session: SleepSession, samples: [SleepStageSample]) -> some View {
        Section("Snoring episodes (\(session.events.count))") {
            if session.events.isEmpty {
                Text("No snoring detected in this session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.events.sorted { $0.startDate < $1.startDate }) { event in
                AnalysisEventRow(
                    event: event,
                    stage: SleepAnalysis.dominantStage(for: event, samples: samples),
                    player: player,
                    recordingActive: engine.isRunning,
                    isSelected: selectedEventID == event.persistentModelID
                )
                .id(event.persistentModelID)
            }
        }
    }

    private func minuteString(_ interval: TimeInterval) -> String {
        let minutes = interval / 60
        return minutes >= 10 ? "\(Int(minutes.rounded()))m" : String(format: "%.1fm", minutes)
    }
}

// MARK: - Combined timeline (sleep-stage lanes + snore overlays)

private struct SleepTimelineView: View {
    let samples: [SleepStageSample]
    let events: [SnoreEvent]
    let interval: DateInterval
    @Binding var selectedEventID: PersistentIdentifier?

    private let laneCount = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let labelHeight: CGFloat = 16
            let plotHeight = geo.size.height - labelHeight
            let laneHeight = plotHeight / CGFloat(laneCount)
            let total = max(interval.duration, 1)

            ZStack(alignment: .topLeading) {
                // Lane separators
                ForEach(1..<4) { lane in
                    Rectangle()
                        .fill(Color(.separator).opacity(0.4))
                        .frame(width: width, height: 0.5)
                        .offset(y: CGFloat(lane) * laneHeight)
                }

                // Sleep-stage bars
                ForEach(samples) { sample in
                    let x = CGFloat(sample.start.timeIntervalSince(interval.start) / total) * width
                    let w = max(CGFloat(sample.duration / total) * width, 2)
                    let y = CGFloat(sample.stage.laneIndex) * laneHeight
                    RoundedRectangle(cornerRadius: min(6, w / 2))
                        .fill(sample.stage.color)
                        .frame(width: w, height: laneHeight * 0.72)
                        .offset(x: x, y: y + laneHeight * 0.14)
                }

                // Snore overlays: translucent stripes across all lanes
                ForEach(events) { event in
                    let x = CGFloat(event.startDate.timeIntervalSince(interval.start) / total) * width
                    let w = max(CGFloat(event.duration / total) * width, 3)
                    let isSelected = selectedEventID == event.persistentModelID
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.orange.opacity(isSelected ? 0.65 : 0.32))
                        .frame(width: w, height: plotHeight)
                        .overlay(alignment: .top) {
                            if isSelected {
                                Image(systemName: "waveform")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .offset(y: -2)
                            }
                        }
                        .offset(x: x)
                        .onTapGesture {
                            selectedEventID = event.persistentModelID
                        }
                }

                // Time axis labels
                HStack {
                    Text(interval.start, style: .time)
                    Spacer()
                    Text(interval.end, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: plotHeight + 2)
            }
        }
    }
}

// MARK: - Event row (stage tag + waveform scrubber playback)

private struct AnalysisEventRow: View {
    let event: SnoreEvent
    let stage: SleepStage?
    let player: ClipPlayer
    let recordingActive: Bool
    let isSelected: Bool

    @State private var waveform: WaveformData?

    private var clipURL: URL? {
        guard let url = event.clipURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private var isActive: Bool { clipURL != nil && player.activeURL == clipURL }
    private var isPlaying: Bool { isActive && player.isPlaying }

    private var clipDuration: TimeInterval {
        if isActive, player.duration > 0 { return player.duration }
        return waveform?.duration ?? event.duration
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.startDate, style: .time)
                        .font(.subheadline.monospacedDigit())
                    HStack(spacing: 6) {
                        if let stage {
                            HStack(spacing: 3) {
                                Circle().fill(stage.color).frame(width: 7, height: 7)
                                Text(stage.rawValue)
                            }
                        }
                        Text("\(Int(event.duration)) s · peak \(String(format: "%.0f%%", event.peakConfidence * 100))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = clipURL {
                    Button {
                        player.togglePlay(url: url, recordingActive: recordingActive)
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(isPlaying ? .orange : .accentColor)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.tertiary)
                }
            }

            if let url = clipURL {
                WaveformScrubber(
                    waveform: waveform,
                    progress: clipDuration > 0 ? (isActive ? player.currentTime : 0) / clipDuration : 0
                ) { fraction in
                    player.seek(url: url, to: fraction * clipDuration,
                                recordingActive: recordingActive)
                }
                .frame(height: 30)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.orange.opacity(0.12) : nil)
        .task(id: event.clipFileName) {
            if let url = clipURL, waveform == nil {
                waveform = await WaveformStore.shared.waveform(for: url)
            }
        }
    }
}
