import AppKit
import Foundation
import Combine
import SwiftUI
import CoreAudio

/// Holds a `Sendable` result across a background `DispatchQueue` hop without mutating a captured `var`.
final class SendableResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ v: T?) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func take() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum NowPlayingSource: Equatable, Sendable {
    case spotify
    case appleMusic
    case browser(name: String)
    case unknown
}

enum PlaybackState: String, Sendable {
    case idle
    case playing
    case paused
}

struct AudioSession: Equatable, Sendable {
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var source: NowPlayingSource
    var playback: PlaybackState
    var canPlayPause: Bool
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
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

final class AudioOutputDeviceService {
    func fetchOutputDevices() -> [AudioOutputDevice] {
        let defaultDeviceID = getDefaultOutputDeviceID()
        let ids = getAllDeviceIDs()
        var devices: [AudioOutputDevice] = []

        for id in ids where isOutputDevice(id) {
            let name = getDeviceName(id) ?? "Unknown Output"
            devices.append(AudioOutputDevice(id: id, name: name, isDefault: id == defaultDeviceID))
        }

        return devices.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let outputStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &id
        )

        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            0,
            nil,
            size,
            &id
        )

        return outputStatus == noErr || systemStatus == noErr
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        return status == noErr ? deviceID : 0
    }

    private func getAllDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }

        return ids
    }

    private func isOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func getDeviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var cfName: CFString = "" as CFString
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr else { return nil }
        return cfName as String
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
