import AppKit
import Foundation
import Combine
import SwiftUI

enum NowPlayingSource: Equatable {
    case spotify
    case appleMusic
    case browser(name: String)
    case unknown
}

enum PlaybackState: String {
    case idle
    case playing
    case paused
}

struct AudioSession: Equatable {
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var source: NowPlayingSource
    var playback: PlaybackState
    var canPlayPause: Bool
}

enum ScriptError: Error {
    case noResult
    case notString
}

final class AppleScriptRunner {
    func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ScriptError.noResult }
        let output = script.executeAndReturnError(&error)
        if let error = error as? [String: Any] {
            throw NSError(domain: "AppleScriptError", code: 1, userInfo: error)
        }
        guard let s = output.stringValue else { throw ScriptError.notString }
        return s
    }
}

final class MediaKeySender {
    private enum NXKey: UInt32 {
        case play = 16
        case next = 17
        case previous = 18
    }

    private func postAuxKey(_ key: UInt32) {
        func doKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))

            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: NSPoint(x: 0, y: 0),
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }

        doKey(down: true)
        doKey(down: false)
    }

    func togglePlayPause() {
        postAuxKey(NXKey.play.rawValue)
    }

    func nextTrack() {
        postAuxKey(NXKey.next.rawValue)
    }

    func previousTrack() {
        postAuxKey(NXKey.previous.rawValue)
    }
}

final class IslandState: ObservableObject {
    @Published var expanded: Bool = false
}

struct InternalNotification: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String?
    var createdAt: Date = Date()
    var ttl: TimeInterval
}

@MainActor
final class NotificationsStore: ObservableObject {
    @Published private(set) var notifications: [InternalNotification] = []

    func push(title: String, message: String? = nil, ttl: TimeInterval = 3.5) {
        let item = InternalNotification(title: title, message: message, ttl: ttl)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            notifications.insert(item, at: 0)
        }

        let id = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            notifications.removeAll { $0.id == id }
        }
    }
}
