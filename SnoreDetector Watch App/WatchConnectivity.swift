//
//  WatchConnectivity.swift
//  SnoreDetector Watch App  (watchOS target)
//
//  Sends Start/Stop to the iPhone and mirrors the phone's recording state.
//  The Watch never records audio — the iPhone is the recorder; this is a remote.
//
//  Observable state lives here; a separate NSObject is the WCSessionDelegate.
//

import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivity {
    private(set) var isPhoneReachable = false
    /// Mirror of the phone's recording state.
    private(set) var isRunning = false
    private(set) var sessionStart: Date?
    /// True briefly after sending a command while waiting for the phone to confirm.
    private(set) var pending = false

    private var proxy: WCDelegateProxy?

    init() {
        guard WCSession.isSupported() else { return }
        let proxy = WCDelegateProxy(owner: self)
        self.proxy = proxy
        let session = WCSession.default
        session.delegate = proxy
        session.activate()
    }

    func toggle() {
        send(command: isRunning ? .stop : .start)
    }

    func requestStatus() {
        send(command: .requestStatus)
    }

    private func send(command: SnoreWCCommand) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let payload: [String: Any] = [SnoreWCKey.command: command.rawValue]

        if command != .requestStatus { pending = true }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Fall back to the queued path if the live message fails.
                WCSession.default.transferUserInfo(payload)
            }
        } else {
            // Phone app not active — queue it; the system wakes the phone.
            session.transferUserInfo(payload)
        }
    }

    fileprivate func apply(_ payload: [String: Any]) {
        if let running = payload[SnoreWCKey.isRunning] as? Bool {
            isRunning = running
            pending = false
        }
        if let start = payload[SnoreWCKey.sessionStart] as? TimeInterval {
            sessionStart = Date(timeIntervalSince1970: start)
        } else if payload[SnoreWCKey.isRunning] as? Bool == false {
            sessionStart = nil
        }
    }

    fileprivate func setReachable(_ reachable: Bool) {
        isPhoneReachable = reachable
    }
}

// MARK: - WCSessionDelegate (separate NSObject)

private final class WCDelegateProxy: NSObject, WCSessionDelegate {
    weak var owner: WatchConnectivity?

    init(owner: WatchConnectivity) {
        self.owner = owner
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor [owner] in
            owner?.setReachable(reachable)
            owner?.requestStatus()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [owner] in
            owner?.setReachable(reachable)
            if reachable { owner?.requestStatus() }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [owner] in owner?.apply(message) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        Task { @MainActor [owner] in owner?.apply(ctx) }
    }
}
