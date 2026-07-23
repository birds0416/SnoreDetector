//
//  HealthKitManager.swift
//  SnoreDetector
//
//  Read-only Apple Health sleep-stage integration (M5).
//
//  - Reads HKCategoryTypeIdentifier.sleepAnalysis samples (REM/Core/Deep/Awake),
//    which typically come from an Apple Watch.
//  - Reversible: the in-app toggle (Settings tab) gates ALL queries. iOS read
//    permission itself can be revoked in the Health app; iOS never tells apps
//    whether read access was denied (privacy), so "no data" and "denied" look
//    identical — the UI copy accounts for that.
//  - Samples are cached per session so the Analysis tab doesn't re-query
//    HealthKit every time it opens.
//

import Foundation
import HealthKit
import Observation
import SwiftUI

// MARK: - Sleep stage model

enum SleepStage: String, CaseIterable, Identifiable {
    case awake = "Awake"
    case rem = "REM"
    case core = "Core"
    case deep = "Deep"

    var id: String { rawValue }

    /// Colors matched to Apple Health's sleep chart.
    var color: Color {
        switch self {
        case .awake: return Color(red: 1.00, green: 0.42, blue: 0.34)
        case .rem:   return Color(red: 0.32, green: 0.78, blue: 0.98)
        case .core:  return Color(red: 0.06, green: 0.46, blue: 1.00)
        case .deep:  return Color(red: 0.28, green: 0.25, blue: 0.68)
        }
    }

    /// Lane order in the timeline, matching Apple Health (Awake on top).
    var laneIndex: Int {
        switch self {
        case .awake: return 0
        case .rem: return 1
        case .core: return 2
        case .deep: return 3
        }
    }
}

struct SleepStageSample: Identifiable {
    let id = UUID()
    let stage: SleepStage
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func overlap(with interval: DateInterval) -> TimeInterval {
        let s = max(start, interval.start)
        let e = min(end, interval.end)
        return max(0, e.timeIntervalSince(s))
    }
}

// MARK: - Manager

@Observable
final class HealthKitManager {

    /// App-level switch, persisted. Turning it off stops all Health queries.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "healthKitEnabled")
            if !isEnabled { cache.removeAll() }
        }
    }

    /// Whether we've shown the system permission sheet at least once.
    private(set) var authorizationRequested: Bool

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private var cache: [UUID: [SleepStageSample]] = [:]

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "healthKitEnabled")
        authorizationRequested = UserDefaults.standard.bool(forKey: "healthKitAuthRequested")
    }

    /// Shows the system Health permission sheet (read-only, sleep analysis).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        let sleepType = HKCategoryType(.sleepAnalysis)
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
            authorizationRequested = true
            UserDefaults.standard.set(true, forKey: "healthKitAuthRequested")
            return true
        } catch {
            return false
        }
    }

    /// Sleep samples overlapping a session's time range (cached per session).
    /// Uses the actual sample time range — not calendar days — so sessions
    /// crossing midnight pair with the right night automatically.
    func sleepSamples(for sessionID: UUID, start: Date, end: Date) async -> [SleepStageSample] {
        guard isEnabled, Self.isAvailable else { return [] }
        if let cached = cache[sessionID] { return cached }

        if !authorizationRequested {
            await requestAuthorization()
        }

        let raw = await querySamples(start: start, end: end)
        cache[sessionID] = raw
        return raw
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func querySamples(start: Date, end: Date) async -> [SleepStageSample] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        // If real stage data exists (Watch), ignore unstaged "asleepUnspecified"
        // samples (iPhone-only estimates) so sources don't double-count.
        let hasStageData = samples.contains {
            [HKCategoryValueSleepAnalysis.asleepREM.rawValue,
             HKCategoryValueSleepAnalysis.asleepCore.rawValue,
             HKCategoryValueSleepAnalysis.asleepDeep.rawValue].contains($0.value)
        }

        return samples.compactMap { sample -> SleepStageSample? in
            let stage: SleepStage?
            switch sample.value {
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                stage = .awake
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                stage = .rem
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                stage = .core
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                stage = .deep
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                // Unstaged sleep (no Watch): show as Core so the night is visible.
                stage = hasStageData ? nil : .core
            default:
                stage = nil // .inBed and unknown values are not stages
            }
            guard let stage, sample.endDate > sample.startDate else { return nil }
            return SleepStageSample(stage: stage, start: sample.startDate, end: sample.endDate)
        }
    }
}
