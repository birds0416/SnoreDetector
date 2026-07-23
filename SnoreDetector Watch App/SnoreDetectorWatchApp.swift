//
//  SnoreDetectorWatchApp.swift
//  SnoreDetector Watch App  (watchOS target)
//

import SwiftUI

@main
struct SnoreDetectorWatchApp: App {
    @State private var connectivity = WatchConnectivity()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(connectivity)
        }
    }
}
