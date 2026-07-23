//
//  Models.swift
//  SnoreDetector
//
//  SwiftData models: one SleepSession per night, containing SnoreEvents.
//

import Foundation
import SwiftData

@Model
final class SleepSession {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \SnoreEvent.session)
    var events: [SnoreEvent] = []

    init(startDate: Date = Date()) {
        self.id = UUID()
        self.startDate = startDate
    }

    var duration: TimeInterval {
        (endDate ?? Date()).timeIntervalSince(startDate)
    }

    var totalSnoreDuration: TimeInterval {
        events.reduce(0) { $0 + $1.duration }
    }

    var snorePercentage: Double {
        duration > 0 ? totalSnoreDuration / duration * 100 : 0
    }

    /// Folder where this session's audio clips live.
    var folderURL: URL {
        SleepSession.sessionsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static var sessionsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}

@Model
final class SnoreEvent {
    var startDate: Date
    var endDate: Date
    var peakConfidence: Double
    var clipFileName: String?
    var session: SleepSession?

    init(startDate: Date, endDate: Date, peakConfidence: Double, clipFileName: String?) {
        self.startDate = startDate
        self.endDate = endDate
        self.peakConfidence = peakConfidence
        self.clipFileName = clipFileName
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var clipURL: URL? {
        guard let session, let clipFileName else { return nil }
        return session.folderURL.appendingPathComponent(clipFileName)
    }
}
