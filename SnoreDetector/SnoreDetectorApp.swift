//
//  SnoreDetectorApp.swift
//  SnoreDetector
//
//  Entry point: SwiftData container + shared engine, HealthKit, recording
//  coordinator, and the Apple Watch connectivity relay.
//

import SwiftData
import SwiftUI

@main
struct SnoreDetectorApp: App {
    @State private var engine: SnoreDetectionEngine
    @State private var healthKit = HealthKitManager()
    @State private var coordinator: RecordingCoordinator
    @State private var phone: PhoneConnectivity
    private let container: ModelContainer

    init() {
        let container = try! ModelContainer(for: SleepSession.self, SnoreEvent.self)
        let engine = SnoreDetectionEngine()
        let coordinator = RecordingCoordinator(engine: engine)
        coordinator.attach(modelContext: container.mainContext)

        self.container = container
        _engine = State(initialValue: engine)
        _coordinator = State(initialValue: coordinator)
        _phone = State(initialValue: PhoneConnectivity(coordinator: coordinator))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SessionView()
                    .tabItem { Label("Record", systemImage: "mic.fill") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.fill") }
                AnalysisView()
                    .tabItem { Label("Analysis", systemImage: "chart.bar.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .environment(engine)
            .environment(healthKit)
            .environment(coordinator)
            .environment(phone)
        }
        .modelContainer(container)
    }
}
