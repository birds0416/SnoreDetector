//
//  WatchContentView.swift
//  SnoreDetector Watch App  (watchOS target)
//
//  Minimal remote: one big Start/Stop button, session status, and the
//  phone-connection indicator. The phone does the recording.
//

import Combine
import SwiftUI

struct WatchContentView: View {
    @Environment(WatchConnectivity.self) private var wc
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            connectionRow

            if wc.isRunning, let start = wc.sessionStart {
                Text(elapsed(since: start))
                    .font(.system(.title3, design: .monospaced))
                Text("Recording on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(wc.pending ? "…" : "Ready")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                wc.toggle()
            } label: {
                Text(wc.isRunning ? "Stop" : "Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .tint(wc.isRunning ? .red : .green)
            .disabled(wc.pending)
        }
        .padding(.horizontal, 4)
        .onReceive(clock) { now = $0 }
        .onAppear { wc.requestStatus() }
    }

    private var connectionRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(wc.isPhoneReachable ? .green : .gray)
                .frame(width: 7, height: 7)
            Text(wc.isPhoneReachable ? "iPhone connected" : "iPhone not reachable")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
