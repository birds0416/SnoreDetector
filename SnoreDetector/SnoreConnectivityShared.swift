//
//  SnoreConnectivityShared.swift
//  SnoreDetector  +  SnoreDetector Watch App  (Target Membership: BOTH)
//
//  Tiny shared vocabulary for the phone <-> watch WatchConnectivity link.
//  Add this file to both the iOS app target and the watchOS app target.
//

import Foundation

enum SnoreWCKey {
    static let command = "command"       // value: SnoreWCCommand.rawValue
    static let isRunning = "isRunning"   // Bool — phone's current recording state
    static let sessionStart = "sessionStart" // TimeInterval since 1970, or absent
}

enum SnoreWCCommand: String {
    case start
    case stop
    case requestStatus   // watch asks the phone for its current state
}
