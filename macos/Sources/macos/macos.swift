import AppKit
import Combine
import SwiftUI

enum NowPlayingSource: String {
    case spotify
    case chrome
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

final class SpotifyNowPlayingProvider {
    private let runner = AppleScriptRunner()

    func fetch() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return ""
        end tell
        tell application "Spotify"
          set pState to player state as string
          set tName to ""
          set tArtist to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
          end try
          return pState & "||" & tName & "||" & tArtist
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        if title.isEmpty {
            return AudioSession(title: "Spotify", subtitle: nil, source: .spotify, playback: playback, canPlayPause: true)
        }
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
            source: .spotify,
            playback: playback,
            canPlayPause: true
        )
    }

    func togglePlayPause() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to playpause
        """
        _ = try? runner.run(script)
    }
}

final class ChromeNowPlayingProvider {
    private let runner = AppleScriptRunner()

    func fetchActiveTabTitle() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Google Chrome" then return ""
        end tell
        tell application "Google Chrome"
          if (count of windows) is 0 then return ""
          set t to title of active tab of front window
          return t
        end tell
        """

        guard let title = try? runner.run(script).trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        return AudioSession(
            title: title,
            subtitle: "Chrome",
            source: .chrome,
            playback: .playing,
            canPlayPause: false
        )
    }
}

final class NowPlayingService: ObservableObject {
    @Published private(set) var session: AudioSession? = nil

    private let spotify = SpotifyNowPlayingProvider()
    private let chrome = ChromeNowPlayingProvider()
    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = self.spotify.fetch() ?? self.chrome.fetchActiveTabTitle()
            if next != self.session { self.session = next }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func togglePlayPauseIfSupported() {
        guard session?.source == .spotify, session?.canPlayPause == true else { return }
        spotify.togglePlayPause()
    }
}

struct IslandView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                if nowPlaying.session?.source == .spotify {
                    nowPlaying.togglePlayPauseIfSupported()
                } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    if expanded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            if let subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: expanded ? 360 : 270, height: expanded ? 44 : 40)
                .background(.black.opacity(0.92))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Expanded panel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("We’ll add notifications + device switcher next.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.66))
                }
                .padding(14)
                .frame(width: 720, alignment: .leading)
                .background(.black.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 0)
        .background(Color.clear)
    }

    private var title: String {
        nowPlaying.session?.title ?? "Nothing playing"
    }

    private var subtitle: String? {
        nowPlaying.session?.subtitle ?? "Spotify / Chrome"
    }

    private var iconName: String {
        switch nowPlaying.session?.source {
        case .spotify: "dot.radiowaves.left.and.right"
        case .chrome: "globe"
        default: "music.note"
        }
    }
}

@MainActor
final class IslandPanelController {
    private let panel: NSPanel

    init(rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = hosting
    }

    func show() {
        positionTopCenter()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let size = panel.frame.size
        let x = frame.minX + (frame.width - size.width) / 2
        let y = frame.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let nowPlaying = NowPlayingService()
    private var panelController: IslandPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        nowPlaying.start()
        panelController = IslandPanelController(rootView: IslandView(nowPlaying: nowPlaying))
        panelController?.show()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule", accessibilityDescription: "Dynamic Island")
        item.button?.target = self
        item.button?.action = #selector(toggleIsland)
        statusItem = item

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "i"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func toggleIsland() {
        panelController?.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
final class MenuBarIslandApp: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
