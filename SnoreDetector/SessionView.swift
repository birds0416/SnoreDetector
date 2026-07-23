//
//  SessionView.swift
//  SnoreDetector
//
//  Live recording screen: start/stop, live snoring confidence,
//  tonight's detected events, and a debug log for testing.
//

import Combine
import SwiftData
import SwiftUI

struct SessionView: View {
    @Environment(SnoreDetectionEngine.self) private var engine
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(PhoneConnectivity.self) private var phone

    @State private var showDebugLog = false
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader
                    startStopButton
                    watchStatusRow
                    if engine.isRunning { liveMeter }
                    if !engine.liveEvents.isEmpty { eventList }
                    if let errorMessage = coordinator.lastError {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    debugSection
                }
                .padding()
            }
            .navigationTitle("Snore Detector")
            .onReceive(clock) { now = $0 }
        }
    }

    // Apple Watch connection indicator (only meaningful once the Watch app is installed).
    @ViewBuilder private var watchStatusRow: some View {
        if phone.isPaired && phone.isWatchAppInstalled {
            HStack(spacing: 6) {
                Image(systemName: "applewatch")
                Circle()
                    .fill(phone.isWatchReachable ? .green : .gray)
                    .frame(width: 7, height: 7)
                Text(phone.isWatchReachable ? "Watch connected" : "Watch app installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sections

    private var statusHeader: some View {
        VStack(spacing: 8) {
            if engine.isRunning, let start = engine.sessionStartDate {
                Text(elapsedString(since: start))
                    .font(.system(size: 44, weight: .light, design: .monospaced))
                Text(engine.isSnoringNow ? "Snoring detected" : "Listening…")
                    .font(.headline)
                    .foregroundStyle(engine.isSnoringNow ? .orange : .secondary)
            } else {
                Text("Ready")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Tap Start before you go to sleep. Keep the phone plugged in and near your bed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    private var startStopButton: some View {
        Button {
            if engine.isRunning {
                stopSession()
            } else {
                Task { await startSession() }
            }
        } label: {
            Text(engine.isRunning ? "Stop" : "Start")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRunning ? .red : .green)
    }

    private var liveMeter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Snoring confidence")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", engine.currentConfidence * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(engine.isSnoringNow ? .orange : .secondary)
            }
            ProgressView(value: engine.currentConfidence)
                .tint(engine.isSnoringNow ? .orange : .blue)
            Text("Threshold: \(String(format: "%.0f%%", engine.confidenceThreshold * 100))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tonight — \(engine.liveEvents.count) snoring episode\(engine.liveEvents.count == 1 ? "" : "s")")
                .font(.headline)
            ForEach(engine.liveEvents.reversed()) { event in
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text(event.start, style: .time)
                            .font(.subheadline.monospacedDigit())
                        Text("\(Int(event.end.timeIntervalSince(event.start))) s · peak \(String(format: "%.0f%%", event.peakConfidence * 100))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Debug log", isOn: $showDebugLog)
                .font(.subheadline)
            if showDebugLog {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.debugLog.suffix(30).reversed(), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Actions
    // Start/stop go through the shared RecordingCoordinator so the phone UI and
    // the Apple Watch drive the exact same code path. After each, push state to
    // the Watch so its button stays in sync.

    private func startSession() async {
        await coordinator.start()
        phone.syncStateToWatch()
    }

    private func stopSession() {
        coordinator.stop()
        phone.syncStateToWatch()
    }

    private func elapsedString(since start: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
