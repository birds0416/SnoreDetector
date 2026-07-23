//
//  SnoreDetectionEngine.swift
//  SnoreDetector
//
//  Core engine: records audio all night, classifies it in real time with
//  Apple's built-in SoundAnalysis "snoring" class, segments snoring into
//  events (hysteresis), and writes ONLY snoring audio to disk as .m4a clips
//  with a pre-roll so the first snore of each episode is captured.
//
//  Non-snoring audio is never written to disk.
//

import AVFoundation
import CoreML
import Foundation
import Observation
import SoundAnalysis

@Observable
final class SnoreDetectionEngine {

    // MARK: - Observable state (main thread)

    private(set) var isRunning = false
    private(set) var currentConfidence: Double = 0
    private(set) var isSnoringNow = false
    private(set) var liveEvents: [LiveEvent] = []
    private(set) var debugLog: [String] = []
    private(set) var sessionStartDate: Date?

    struct LiveEvent: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
        let peakConfidence: Double
        let clipFileName: String?
    }

    /// Called on the main thread whenever a snore event is finalized,
    /// so the UI layer can persist it with SwiftData.
    var onEventFinished: ((_ start: Date, _ end: Date, _ peak: Double, _ clipFileName: String?) -> Void)?

    // MARK: - Tuning knobs (tune these after real overnight tests)

    /// A window counts as "snoring" when the classifier's confidence is at least this.
    var confidenceThreshold: Double = 0.6
    /// Analysis window length in seconds (classifier looks at chunks of this size).
    private let windowDuration: TimeInterval = 1.5
    /// Consecutive positive windows required to START an event (rejects one-off blips).
    private let consecutiveToStart = 2
    /// Seconds without a positive window before an event ENDS
    /// (merges individual snores ~3-6 s apart into one snoring episode).
    private let endHangover: TimeInterval = 10
    /// Seconds of audio kept in memory so a clip includes what came just before detection.
    private let preRollDuration: TimeInterval = 10

    // MARK: - Private audio state

    private let audioEngine = AVAudioEngine()
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var resultsObserver: SnoreResultsObserver? // retained; analyzer may not retain it
    private let analysisQueue = DispatchQueue(label: "com.snoredetector.analysis")
    private var inputFormat: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0

    // Ring buffer for pre-roll (accessed only on analysisQueue)
    private var ringBuffer: [AVAudioPCMBuffer] = []
    private var ringFrameCount: AVAudioFrameCount = 0

    // Segmentation state (accessed only on analysisQueue)
    private var positiveStreak = 0
    private var eventActive = false
    private var eventStartDate: Date?
    private var eventPeak: Double = 0
    private var lastPositiveDate: Date?
    private var clipFile: AVAudioFile?
    private var clipFileName: String?
    private var sessionFolder: URL?
    private var analysisFailureLogged = false

    // MARK: - Permissions

    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Start / Stop

    /// Starts an all-night monitoring session. Clips are written into `sessionFolder`.
    func start(sessionFolder: URL) throws {
        guard !isRunning else { return }

        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        self.sessionFolder = sessionFolder

        // 1. Audio session: .record keeps the mic running in the background
        //    (with UIBackgroundModes=audio) while the phone is locked all night.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        observeInterruptions()

        // 2. Live audio tap.
        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SnoreDetector", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input available. On the simulator: allow microphone access for Simulator in macOS System Settings > Privacy & Security > Microphone, and check the Simulator menu I/O > Audio Input."
            ])
        }
        self.inputFormat = format
        framePosition = 0

        // 3. Sound classifier.
        // IMPORTANT: iOS 18+ forbids GPU/Neural Engine work from backgrounded apps,
        // and Apple's built-in classifier is GPU-bound — it silently fails on every
        // window once the screen locks, even though the mic keeps recording.
        // Fix: our own Create ML model forced to CPU-only (CPU inference IS allowed
        // in the background). Falls back to the built-in classifier if the custom
        // model isn't bundled — foreground-only in that case.
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request: SNClassifySoundRequest
        if let modelURL = Bundle.main.url(forResource: "SnoreClassifier", withExtension: "mlmodelc") {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            request = try SNClassifySoundRequest(mlModel: model)
            log("Custom CPU-only snore model loaded — locked-screen detection enabled.")
        } else {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // The custom model's window is fixed by training (~1 s); only the
            // built-in classifier accepts a custom window duration.
            request.windowDuration = CMTimeMakeWithSeconds(windowDuration, preferredTimescale: 48_000)
            log("⚠️ Built-in classifier — detection will NOT work with the screen locked (iOS 18+).")
        }
        request.overlapFactor = 0.5
        let observer = SnoreResultsObserver(engine: self)
        try analyzer.add(request, withObserver: observer)
        self.resultsObserver = observer
        self.streamAnalyzer = analyzer

        // Reset per-session state.
        analysisQueue.sync {
            ringBuffer.removeAll()
            ringFrameCount = 0
            positiveStreak = 0
            eventActive = false
            eventStartDate = nil
            eventPeak = 0
            lastPositiveDate = nil
            clipFile = nil
            clipFileName = nil
            analysisFailureLogged = false
        }

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, time in
            guard let self, let copy = buffer.deepCopy() else { return }
            let position = time.sampleTime
            self.analysisQueue.async {
                self.streamAnalyzer?.analyze(copy, atAudioFramePosition: position)
                self.handleAudioBuffer(copy)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        sessionStartDate = Date()
        liveEvents = []
        isRunning = true
        log("Session started. Input: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    /// Stops the session, finalizing any in-progress snore event.
    func stop() {
        guard isRunning else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        analysisQueue.sync {
            if eventActive {
                finishEvent(endDate: Date())
            }
            streamAnalyzer?.completeAnalysis()
            streamAnalyzer = nil
            resultsObserver = nil
            ringBuffer.removeAll()
            ringFrameCount = 0
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        isRunning = false
        isSnoringNow = false
        currentConfidence = 0
        log("Session stopped.")
    }

    // MARK: - Buffer handling (analysisQueue only)

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // While a snore event is active, stream audio straight into the clip file.
        if eventActive, let file = clipFile {
            do {
                try file.write(from: buffer)
            } catch {
                log("Clip write error: \(error.localizedDescription)")
            }
            return // no need to also keep it in the ring buffer
        }

        // Otherwise maintain the pre-roll ring buffer (in memory only).
        ringBuffer.append(buffer)
        ringFrameCount += buffer.frameLength

        guard let format = inputFormat else { return }
        let maxFrames = AVAudioFrameCount(preRollDuration * format.sampleRate)
        while ringFrameCount > maxFrames, !ringBuffer.isEmpty {
            let removed = ringBuffer.removeFirst()
            ringFrameCount -= removed.frameLength
        }
    }

    // MARK: - Segmentation state machine (analysisQueue only)

    private func processClassification(snoringConfidence: Double) {
        let now = Date()
        let positive = snoringConfidence >= confidenceThreshold

        DispatchQueue.main.async {
            self.currentConfidence = snoringConfidence
            self.isSnoringNow = positive
        }

        if positive {
            positiveStreak += 1
            lastPositiveDate = now
            if eventActive {
                eventPeak = max(eventPeak, snoringConfidence)
            } else if positiveStreak >= consecutiveToStart {
                beginEvent(at: now, confidence: snoringConfidence)
            }
        } else {
            positiveStreak = 0
            if eventActive, let last = lastPositiveDate,
               now.timeIntervalSince(last) >= endHangover {
                finishEvent(endDate: last.addingTimeInterval(windowDuration))
            }
        }
    }

    private func beginEvent(at date: Date, confidence: Double) {
        guard let folder = sessionFolder, let format = inputFormat else { return }

        eventActive = true
        // Backdate the start to cover the windows that triggered detection.
        eventStartDate = date.addingTimeInterval(-windowDuration * Double(consecutiveToStart))
        eventPeak = confidence

        // Create the clip file (AAC .m4a) and flush the pre-roll into it.
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let name = "snore_\(formatter.string(from: date)).m4a"
        let url = folder.appendingPathComponent(name)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            for buffered in ringBuffer {
                try file.write(from: buffered)
            }
            ringBuffer.removeAll()
            ringFrameCount = 0
            clipFile = file
            clipFileName = name
            log("Snore event started (confidence \(String(format: "%.2f", confidence)))")
        } catch {
            clipFile = nil
            clipFileName = nil
            log("Could not create clip file: \(error.localizedDescription)")
        }
    }

    private func finishEvent(endDate: Date) {
        guard eventActive, let start = eventStartDate else { return }

        clipFile = nil // closes the file
        let name = clipFileName
        let peak = eventPeak

        eventActive = false
        eventStartDate = nil
        eventPeak = 0
        clipFileName = nil

        DispatchQueue.main.async {
            let event = LiveEvent(start: start, end: endDate, peakConfidence: peak, clipFileName: name)
            self.liveEvents.append(event)
            self.onEventFinished?(start, endDate, peak, name)
        }
        log("Snore event ended (\(String(format: "%.0f", endDate.timeIntervalSince(start))) s)")
    }

    // MARK: - Interruptions (phone calls, Siri, other apps taking the mic)

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                self.log("Audio interrupted (call/Siri). Waiting to resume…")
            case .ended:
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume), self.isRunning {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try self.audioEngine.start()
                        self.log("Audio resumed after interruption.")
                    } catch {
                        self.log("Failed to resume: \(error.localizedDescription)")
                    }
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Debug log

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.debugLog.append(line)
            if self.debugLog.count > 200 {
                self.debugLog.removeFirst(self.debugLog.count - 200)
            }
        }
    }
}

// MARK: - Classification results (called by SnoreResultsObserver)

extension SnoreDetectionEngine {
    fileprivate func handleClassification(snoringConfidence: Double) {
        analysisQueue.async {
            self.processClassification(snoringConfidence: snoringConfidence)
        }
    }

    fileprivate func handleAnalysisFailure(_ error: Error) {
        // In the failing-background case this fires every window — log once per session.
        guard !analysisFailureLogged else { return }
        analysisFailureLogged = true
        log("Sound analysis failed: \(error.localizedDescription)")
    }
}

// MARK: - SNResultsObserving bridge
// Separate NSObject because SNResultsObserving requires NSObjectProtocol,
// and mixing NSObject inheritance with the @Observable macro is fragile.

private final class SnoreResultsObserver: NSObject, SNResultsObserving {
    private weak var engine: SnoreDetectionEngine?

    init(engine: SnoreDetectionEngine) {
        self.engine = engine
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "snoring")?.confidence ?? 0
        engine?.handleClassification(snoringConfidence: confidence)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        engine?.handleAnalysisFailure(error)
    }
}

// MARK: - Buffer deep copy helper

extension AVAudioPCMBuffer {
    /// The tap's buffer is reused by the system; copy it before using it asynchronously.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let srcBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (srcBuf, dstBuf) in zip(srcBuffers, dstBuffers) {
            guard let srcData = srcBuf.mData, let dstData = dstBuf.mData else { return nil }
            memcpy(dstData, srcData, Int(min(srcBuf.mDataByteSize, dstBuf.mDataByteSize)))
        }
        return copy
    }
}
