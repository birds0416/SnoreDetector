//
//  PhoneConnectivity.swift
//  SnoreDetector  (iOS target)
//
//  Receives Start/Stop commands from the Apple Watch and drives the shared
//  RecordingCoordinator. Reports the phone's recording state back to the Watch
//  so both screens stay in sync.
//
//  Delivery model:
//  - Watch reachable (phone app active): commands arrive via didReceiveMessage.
//  - Phone backgrounded / not running: the Watch sends via transferUserInfo,
//    which the system queues and delivers by waking the app in the background.
//    Our `audio` + `processing` background modes let the woken app start the mic.
//
//  The observable state lives here; a separate NSObject (WCDelegateProxy) is the
//  actual WCSessionDelegate, because the @Observable macro and NSObject
//  inheritance don't mix cleanly.
//

import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class PhoneConnectivity {
    private let coordinator: RecordingCoordinator
    private var proxy: WCDelegateProxy?

    private(set) var isWatchReachable = false
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        guard WCSession.isSupported() else { return }
        let proxy = WCDelegateProxy(owner: self)
        self.proxy = proxy
        let session = WCSession.default
        session.delegate = proxy
        session.activate()
    }

    /// Pushes the current recording state to the Watch (best effort).
    func syncStateToWatch() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var payload: [String: Any] = [SnoreWCKey.isRunning: coordinator.isRunning]
        if coordinator.isRunning, let start = coordinator.engine.sessionStartDate {
            payload[SnoreWCKey.sessionStart] = start.timeIntervalSince1970
        }
        // applicationContext always reflects the latest state, even if the Watch
        // app opens later; sendMessage delivers instantly when reachable.
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    fileprivate func handle(command: SnoreWCCommand) {
        switch command {
        case .start:
            Task { await coordinator.start(); syncStateToWatch() }
        case .stop:
            coordinator.stop(); syncStateToWatch()
        case .requestStatus:
            syncStateToWatch()
        }
    }

    fileprivate func updateReachability(reachable: Bool, paired: Bool, installed: Bool) {
        isWatchReachable = reachable
        isPaired = paired
        isWatchAppInstalled = installed
    }
}

// MARK: - WCSessionDelegate (separate NSObject)

private final class WCDelegateProxy: NSObject, WCSessionDelegate {
    weak var owner: PhoneConnectivity?

    init(owner: PhoneConnectivity) {
        self.owner = owner
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        pushReachability(session)
        Task { @MainActor [owner] in owner?.syncStateToWatch() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        pushReachability(session)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        route(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        route(userInfo)
    }

    // iOS requires these for multi-watch support.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    private func pushReachability(_ session: WCSession) {
        let reachable = session.isReachable
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor [owner] in
            owner?.updateReachability(reachable: reachable, paired: paired, installed: installed)
        }
    }

    private func route(_ payload: [String: Any]) {
        guard let raw = payload[SnoreWCKey.command] as? String,
              let command = SnoreWCCommand(rawValue: raw) else { return }
        Task { @MainActor [owner] in owner?.handle(command: command) }
    }
}
