import AppKit
import Foundation
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
    var album: String?
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

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    // Only allow hits in a horizontal band around the top (where the pill/panel live),
    // so clicks outside that band go through to underlying apps like Chrome.
    var hitTestBandHeight: CGFloat = 72

    override func hitTest(_ point: NSPoint) -> NSView? {
        let bandHeight: CGFloat = hitTestBandHeight
        let bandRect = NSRect(
            x: bounds.minX,
            y: bounds.maxY - bandHeight,
            width: bounds.width,
            height: bandHeight
        )
        guard bandRect.contains(point) else {
            return nil
        }
        return super.hitTest(point)
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
          set tAlbum to ""
          set tArtworkURL to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
          end try
          try
            set tArtworkURL to artwork url of current track
          end try
          return pState & "||" & tName & "||" & tArtist & "||" & tAlbum & "||" & tArtworkURL
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURLString = (parts.count > 4 ? parts[4] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        if title.isEmpty {
            return AudioSession(
                title: "Spotify",
                subtitle: nil,
                album: nil,
                artworkURL: nil,
                source: .spotify,
                playback: playback,
                canPlayPause: true
            )
        }
        let artworkURL = artworkURLString.isEmpty ? nil : URL(string: artworkURLString)
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
            album: album.isEmpty ? nil : album,
            artworkURL: artworkURL,
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

    func previousTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to previous track
        """
        _ = try? runner.run(script)
    }

    func nextTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to next track
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

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var session: AudioSession? = nil
    @Published private(set) var artworkImage: NSImage? = nil

    private let spotify = SpotifyNowPlayingProvider()
    private let chrome = ChromeNowPlayingProvider()
    private var timer: Timer?
    private var currentArtworkURL: URL? = nil

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = self.spotify.fetch() ?? self.chrome.fetchActiveTabTitle()
            if next != self.session {
                self.session = next
                if let next {
                    self.refreshArtworkIfNeeded(for: next)
                } else {
                    self.currentArtworkURL = nil
                    self.artworkImage = nil
                }
            }
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

    func previousTrackIfSupported() {
        guard session?.source == .spotify else { return }
        spotify.previousTrack()
    }

    func nextTrackIfSupported() {
        guard session?.source == .spotify else { return }
        spotify.nextTrack()
    }

    private func refreshArtworkIfNeeded(for session: AudioSession) {
        guard session.source == .spotify, let url = session.artworkURL else {
            currentArtworkURL = nil
            artworkImage = nil
            return
        }
        guard currentArtworkURL != url else { return }
        currentArtworkURL = url
        artworkImage = nil

        let urlCopy = url
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: urlCopy)
                // Avoid setting an outdated image after rapid track changes.
                guard self.currentArtworkURL == urlCopy else { return }
                self.artworkImage = NSImage(data: data)
            } catch {
                // Keep existing UI fallback on failures.
            }
        }
    }
}

final class IslandState: ObservableObject {
    @Published var expanded: Bool = false
}

struct SoundVisualizerView: View {
    let isPlaying: Bool
    private let barCount = 24

    private func fract(_ x: Double) -> Double { x - floor(x) }

    /// Spike-based visualizer: sparse peaks with sharp decays.
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Emit only on the right half of the pill (horizontal split),
            // leaving an empty gap on the left next to the notch.
            let emitWidth = width / 2
            // Increase gap so bars are crisp and not a thick block.
            let spacing: CGFloat = 1.05
            let barWidth = max(1, (emitWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

            // Cap spike height so peaks don't visually collide with the notch.
            let maxBarHeight: CGFloat = geo.size.height * 0.85

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let intensity: CGFloat = isPlaying ? 1.0 : 0.25
                let frame = floor(t * 38) // controls spike update rate

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let seed = Double(i) * 13.13 + frame * 0.19
                        let r = fract(sin(seed) * 43758.5453)

                        let threshold = 0.70
                        let exponent = 10.0
                        let spike = max(0, r - threshold)
                        let spikeNorm = pow(spike / (1.0 - threshold), exponent)

                        let decaySeed = Double(i) * 7.77 + frame * 0.37
                        let r2 = fract(sin(decaySeed) * 961.73)
                        let decayPulse = pow(r2, 2.0)

                        let mix = min(1.0, 0.18 * decayPulse + 0.82 * spikeNorm)
                        let height = maxBarHeight * (0.10 + 0.90 * mix) * intensity

                        RoundedRectangle(cornerRadius: max(1, barWidth * 0.2), style: .continuous)
                            .fill(Color.white.opacity(isPlaying ? 0.98 : 0.35))
                            .frame(width: barWidth, height: height)
                    }
                }
                // Keep the bars baseline locked to the bottom and aligned right,
                // and ensure the left half stays empty.
                .frame(width: width, height: geo.size.height, alignment: .bottomTrailing)
            }
        }
        .clipped()
    }
}

struct IslandView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var islandState: IslandState
    @Namespace private var pillNamespace

    var body: some View {
        VStack(spacing: 10) {
            if islandState.expanded {
                HStack(alignment: .center, spacing: 10) {
                    if let img = nowPlaying.artworkImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 40, height: 40)
                    }

                    Text(condensedNowPlayingLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    let canUseSpotifyControls = (nowPlaying.session?.source == .spotify)

                    if canUseSpotifyControls {
                        HStack(spacing: 8) {
                            Button {
                                nowPlaying.previousTrackIfSupported()
                            } label: {
                                Image(systemName: "backward.end.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .disabled(false)

                            Button {
                                nowPlaying.togglePlayPauseIfSupported()
                            } label: {
                                Image(systemName: (nowPlaying.session?.playback == .playing) ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .frame(width: 36, height: 30)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                            .disabled(!(nowPlaying.session?.canPlayPause ?? false))

                            Button {
                                nowPlaying.nextTrackIfSupported()
                            } label: {
                                Image(systemName: "forward.end.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .disabled(false)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                        .matchedGeometryEffect(id: "panel", in: pillNamespace)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        islandState.expanded = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        // Left: current app / source icon
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 20, height: 20)
                            if let album = nowPlaying.session?.album,
                               !album.isEmpty,
                               let img = nowPlaying.artworkImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 18, height: 18)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: iconName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }

                        Spacer(minLength: 0)

                        // Right: soundwaves indicator
                        SoundVisualizerView(isPlaying: nowPlaying.session?.playback == .playing)
                            .frame(width: 80, height: 16, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 360, height: 32)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.92))
                            .matchedGeometryEffect(id: "pill", in: pillNamespace)
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                }
                .buttonStyle(.plain)
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

    private var condensedNowPlayingLine: String {
        let t = nowPlaying.session?.title ?? "Nothing playing"
        var parts: [String] = [t]

        if let artist = nowPlaying.session?.subtitle, !artist.isEmpty {
            parts.append(artist)
        }
        if let album = nowPlaying.session?.album, !album.isEmpty {
            parts.append(album)
        }

        return parts.joined(separator: " • ")
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
    private var isClickThroughEnabled = false
    private let hosting: PassthroughHostingView<AnyView>
    private(set) var isExpanded: Bool = false

    init(rootView: some View) {
        hosting = PassthroughHostingView(rootView: AnyView(rootView))
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.hitTestBandHeight = 72

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 50),
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
        panel.ignoresMouseEvents = isClickThroughEnabled
        panel.contentView = hosting
    }

    func setRootView<V: View>(_ view: V) {
        hosting.rootView = AnyView(view)
    }

    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        panel.ignoresMouseEvents = enabled
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

    func setExpanded(_ expanded: Bool) {
        // Keep the window as small as possible so it doesn't block clicks in other apps.
        isExpanded = expanded
        hosting.hitTestBandHeight = expanded ? 96 : 72
        let targetSize = expanded
        ? NSSize(width: 520, height: 72)
        : NSSize(width: 400, height: 56)
        panel.setContentSize(targetSize)
        positionTopCenter()
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let size = panel.frame.size
        let x = frame.minX + (frame.width - size.width) / 2
        // Nudge down only while expanded so it sits below the menu-bar/notch region.
        // Expanded sits much lower; collapsed pill should clear the notch a bit. Change 40 to 0 when fixed it
        let yNudge: CGFloat = isExpanded ? 50 : 10
        let y = frame.maxY - size.height - yNudge
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let nowPlaying = NowPlayingService()
    private var panelController: IslandPanelController?
    private let islandState = IslandState()
    private var clickThroughEnabled = false
    private var clickThroughMenuItem: NSMenuItem?
    private var mouseDownMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        nowPlaying.start()
        let controller = IslandPanelController(rootView: EmptyView())
        panelController = controller
        controller.setExpanded(false)

        controller.setRootView(IslandView(nowPlaying: nowPlaying, islandState: islandState))
        controller.show()

        // Resize the NSPanel when SwiftUI state changes.
        islandState.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak controller] expanded in
                controller?.setExpanded(expanded)
            }
            .store(in: &cancellables)

        // Collapse when user clicks outside the panel while expanded.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            guard self.islandState.expanded else { return }
            guard let controller = self.panelController else { return }
            // `NSEvent` doesn't consistently expose `locationInScreen` across SDKs;
            // `mouseLocation` is in global screen coordinates.
            let point = NSEvent.mouseLocation
            if !controller.containsScreenPoint(point) {
                Task { @MainActor in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        self.islandState.expanded = false
                    }
                }
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule", accessibilityDescription: "Dynamic Island")
        item.button?.target = self
        item.button?.action = #selector(toggleIsland)
        statusItem = item

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "i"))
        let clickItem = NSMenuItem(title: "Allow clicking through (over apps)",
                                   action: #selector(toggleClickThrough),
                                   keyEquivalent: "")
        clickItem.state = clickThroughEnabled ? .on : .off
        menu.addItem(clickItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        clickThroughMenuItem = clickItem
    }

    @objc private func toggleIsland() {
        panelController?.toggle()
    }

    @objc private func toggleClickThrough() {
        clickThroughEnabled.toggle()
        clickThroughMenuItem?.state = clickThroughEnabled ? .on : .off
        panelController?.setClickThrough(clickThroughEnabled)
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
