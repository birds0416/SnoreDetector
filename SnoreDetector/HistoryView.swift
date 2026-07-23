//
//  HistoryView.swift
//  SnoreDetector
//
//  Past sessions list + per-session detail with a night timeline strip,
//  event log, and clip playback.
//

import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink(value: session) {
                        SessionRow(session: session)
                    }
                }
                .onDelete(perform: deleteSessions)
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "moon.zzz",
                        description: Text("Start a session on the Record tab before you sleep.")
                    )
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: SleepSession.self) { session in
                SessionDetailView(session: session)
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            try? FileManager.default.removeItem(at: session.folderURL)
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

private struct SessionRow: View {
    let session: SleepSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate, format: .dateTime.weekday(.wide).month().day())
                .font(.headline)
            HStack(spacing: 12) {
                Label(session.startDate.formatted(date: .omitted, time: .shortened),
                      systemImage: "moon.fill")
                if let end = session.endDate {
                    Label(end.formatted(date: .omitted, time: .shortened),
                          systemImage: "sun.max.fill")
                }
                Label("\(session.events.count)", systemImage: "waveform")
                    .foregroundStyle(session.events.isEmpty ? Color.secondary : .orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SessionDetailView: View {
    let session: SleepSession
    @State private var player = ClipPlayer()
    @Environment(SnoreDetectionEngine.self) private var engine

    private var sortedEvents: [SnoreEvent] {
        session.events.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        List {
            Section {
                statsHeader
                TimelineStrip(session: session)
                    .frame(height: 56)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Snoring episodes (\(sortedEvents.count))") {
                if sortedEvents.isEmpty {
                    Text("No snoring detected in this session.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedEvents) { event in
                    EventRow(event: event, player: player,
                             recordingActive: engine.isRunning)
                }
            }
        }
        .navigationTitle(session.startDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    private var statsHeader: some View {
        HStack {
            stat(value: durationString(session.duration), label: "In bed")
            Divider()
            stat(value: durationString(session.totalSnoreDuration), label: "Snoring")
            Divider()
            stat(value: String(format: "%.0f%%", session.snorePercentage), label: "of night")
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(value: String, label: String) -> some View {
        VStack {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Horizontal strip representing the whole night; orange bars mark snoring intervals.
private struct TimelineStrip: View {
    let session: SleepSession

    var body: some View {
        GeometryReader { geo in
            let total = max(session.duration, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemFill))

                ForEach(session.events.sorted { $0.startDate < $1.startDate }) { event in
                    let offset = event.startDate.timeIntervalSince(session.startDate) / total
                    let width = max(event.duration / total, 0.004) // keep short events visible
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange)
                        .frame(width: geo.size.width * width)
                        .offset(x: geo.size.width * offset)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(session.startDate, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
                    .offset(y: 16)
            }
            .overlay(alignment: .bottomTrailing) {
                Text((session.endDate ?? Date()), style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
                    .offset(y: 16)
            }
        }
        .padding(.bottom, 16)
    }
}

private struct EventRow: View {
    let event: SnoreEvent
    let player: ClipPlayer
    let recordingActive: Bool

    @State private var waveform: WaveformData?

    private var clipURL: URL? {
        guard let url = event.clipURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private var isActive: Bool {
        clipURL != nil && player.activeURL == clipURL
    }

    private var isPlaying: Bool {
        isActive && player.isPlaying
    }

    /// Clip length: from the loaded player when active, else from the decoded
    /// waveform, else fall back to the detected event duration.
    private var clipDuration: TimeInterval {
        if isActive, player.duration > 0 { return player.duration }
        return waveform?.duration ?? event.duration
    }

    private var position: TimeInterval {
        isActive ? player.currentTime : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.startDate, style: .time)
                        .font(.subheadline.monospacedDigit())
                    Text("\(Int(event.duration)) s · peak \(String(format: "%.0f%%", event.peakConfidence * 100))")
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
                    progress: clipDuration > 0 ? position / clipDuration : 0
                ) { fraction in
                    player.seek(url: url, to: fraction * clipDuration,
                                recordingActive: recordingActive)
                }
                .frame(height: 36)

                HStack {
                    Text(timeString(position))
                    Spacer()
                    Text(timeString(clipDuration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .task(id: event.clipFileName) {
            if let url = clipURL, waveform == nil {
                waveform = await WaveformStore.shared.waveform(for: url)
            }
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
