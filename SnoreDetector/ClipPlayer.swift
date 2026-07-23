//
//  ClipPlayer.swift
//  SnoreDetector
//
//  Audio playback for saved snore clips with seek support and
//  live playback-position tracking for the scrubber UI.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class ClipPlayer {
    /// The clip currently loaded (playing or paused).
    private(set) var activeURL: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var delegateProxy: DelegateProxy?
    private var progressTimer: Timer?

    // MARK: - Controls

    /// Play/pause the given clip. Loads it first if it isn't the active clip.
    /// Does nothing while a recording session is active (don't steal the mic session).
    func togglePlay(url: URL, recordingActive: Bool) {
        if activeURL == url, player != nil {
            isPlaying ? pause() : resume()
            return
        }
        guard load(url: url, recordingActive: recordingActive) else { return }
        resume()
    }

    /// Jump to a time within a clip. Loads the clip (paused) if needed,
    /// so the user can scrub before pressing play.
    func seek(url: URL, to time: TimeInterval, recordingActive: Bool) {
        if activeURL != url || player == nil {
            guard load(url: url, recordingActive: recordingActive) else { return }
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
        currentTime = player.currentTime
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
        if let player { currentTime = player.currentTime }
    }

    func stop() {
        player?.stop()
        player = nil
        delegateProxy = nil
        activeURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopProgressTimer()
    }

    // MARK: - Internals

    @discardableResult
    private func load(url: URL, recordingActive: Bool) -> Bool {
        stop()
        guard !recordingActive else { return false }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            let proxy = DelegateProxy { [weak self] in
                DispatchQueue.main.async { self?.playbackFinished() }
            }
            newPlayer.delegate = proxy
            newPlayer.prepareToPlay()
            player = newPlayer
            delegateProxy = proxy // AVAudioPlayer.delegate is weak; keep it alive
            activeURL = url
            duration = newPlayer.duration
            currentTime = 0
            isPlaying = false
            return true
        } catch {
            stop()
            return false
        }
    }

    private func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startProgressTimer()
    }

    private func playbackFinished() {
        isPlaying = false
        stopProgressTimer()
        currentTime = 0
        player?.currentTime = 0
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player, self.isPlaying else { return }
            self.currentTime = player.currentTime
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // Separate NSObject because AVAudioPlayerDelegate requires NSObjectProtocol,
    // and mixing NSObject inheritance with the @Observable macro is fragile.
    private final class DelegateProxy: NSObject, AVAudioPlayerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}
