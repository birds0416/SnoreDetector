//
//  RecordingCoordinator.swift
//  SnoreDetector
//
//  Owns the start/stop lifecycle of a recording session so it can be driven
//  from either the UI (SessionView) or the Apple Watch (via PhoneConnectivity)
//  — the same code path regardless of who pressed the button.
//
//  Creating a session, wiring event persistence, and setting the session end
//  date all live here rather than in the view, so the Watch can start/stop a
//  session headlessly (e.g. when the app was woken in the background by
//  WatchConnectivity).
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecordingCoordinator {
    let engine: SnoreDetectionEngine
    private var modelContext: ModelContext?
    private var currentSession: SleepSession?

    /// Last error surfaced to the UI (mic denied, engine failure, etc.).
    var lastError: String?

    init(engine: SnoreDetectionEngine) {
        self.engine = engine
    }

    /// Injected once the SwiftData container exists (from the App scene).
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isRunning: Bool { engine.isRunning }

    /// Starts a new night session. Safe to call from the UI or the Watch relay.
    /// Returns true if recording actually began.
    @discardableResult
    func start() async -> Bool {
        guard !engine.isRunning else { return true }
        guard let modelContext else {
            lastError = "Storage not ready."
            return false
        }
        guard await SnoreDetectionEngine.requestMicrophonePermission() else {
            lastError = "Microphone access denied. Enable it in Settings > Privacy > Microphone."
            return false
        }

        let session = SleepSession()
        modelContext.insert(session)
        try? modelContext.save()
        currentSession = session

        engine.onEventFinished = { [weak self] start, end, peak, clipName in
            // Hop to the main actor for SwiftData work.
            Task { @MainActor in
                guard let self, let context = self.modelContext else { return }
                let event = SnoreEvent(startDate: start, endDate: end,
                                       peakConfidence: peak, clipFileName: clipName)
                event.session = session
                context.insert(event)
                try? context.save()
            }
        }

        do {
            try engine.start(sessionFolder: session.folderURL)
            lastError = nil
            return true
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            modelContext.delete(session)
            try? modelContext.save()
            currentSession = nil
            return false
        }
    }

    /// Stops the active session and stamps its end date.
    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
        currentSession?.endDate = Date()
        try? modelContext?.save()
        currentSession = nil
    }
}
