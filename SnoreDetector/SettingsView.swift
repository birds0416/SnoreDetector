//
//  SettingsView.swift
//  SnoreDetector
//
//  App settings: reversible Apple Health integration toggle (M5).
//

import SwiftUI

struct SettingsView: View {
    @Environment(HealthKitManager.self) private var healthKit
    @State private var showUnavailableAlert = false

    var body: some View {
        @Bindable var healthKit = healthKit
        NavigationStack {
            Form {
                Section {
                    Toggle("Apple Health sleep data", isOn: $healthKit.isEnabled)
                        .onChange(of: healthKit.isEnabled) { _, enabled in
                            if enabled {
                                guard HealthKitManager.isAvailable else {
                                    healthKit.isEnabled = false
                                    showUnavailableAlert = true
                                    return
                                }
                                Task { await healthKit.requestAuthorization() }
                            }
                        }
                } header: {
                    Text("Health")
                } footer: {
                    Text("""
                    When enabled, the Analysis tab reads your sleep stages (REM, Core, \
                    Deep, Awake) from Apple Health — read-only — to correlate them with \
                    detected snoring. Sleep stages usually come from an Apple Watch. \
                    Turning this off stops all Health queries immediately. You can also \
                    revoke access anytime in the Health app under Sharing > Apps.
                    """)
                }

                Section {
                    LabeledContent("Detection model", value: "Custom (CPU, on-device)")
                    LabeledContent("Audio storage", value: "On device only")
                } header: {
                    Text("About")
                } footer: {
                    Text("All recording, detection, and analysis run entirely on this device. Nothing is uploaded.")
                }
            }
            .navigationTitle("Settings")
            .alert("Health data unavailable", isPresented: $showUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Apple Health is not available on this device.")
            }
        }
    }
}
