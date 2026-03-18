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
    @Published private(set) var waveformAccentColor: NSColor? = nil

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
                    self.waveformAccentColor = nil
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
            waveformAccentColor = nil
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
                let image = NSImage(data: data)
                self.artworkImage = image
                self.waveformAccentColor = image.map(self.averageAccentColor(from:))
            } catch {
                // Keep existing UI fallback on failures.
            }
        }
    }

    private func averageAccentColor(from image: NSImage) -> NSColor {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .white
        }

        // Downsample for speed.
        let targetW: Int = 32
        let targetH: Int = 32
        let width = targetW
        let height = targetH

        let bytesPerRow = width * 4
        let bitsPerComponent = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .white
        }

        // Draw with aspect-fit.
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.clear(rect)
        ctx.draw(cgImage, in: rect)

        guard let data = ctx.data else {
            return .white
        }

        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var rTotal: Double = 0
        var gTotal: Double = 0
        var bTotal: Double = 0
        var count: Double = 0

        // Sample every pixel; the image is tiny (32x32).
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(ptr[offset + 0])
            let g = Double(ptr[offset + 1])
            let b = Double(ptr[offset + 2])
            let a = Double(ptr[offset + 3]) / 255.0

            guard a > 0.1 else { continue }

            // Ignore near-black pixels to avoid returning black for dark covers.
            let brightness = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            guard brightness > 0.05 else { continue }

            rTotal += r
            gTotal += g
            bTotal += b
            count += 1
        }

        guard count > 0 else { return .white }
        return NSColor(
            red: CGFloat(rTotal / count / 255.0),
            green: CGFloat(gTotal / count / 255.0),
            blue: CGFloat(bTotal / count / 255.0),
            alpha: 1.0
        )
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

struct NotificationToastView: View {
    let item: InternalNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            if let message = item.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 10)
    }
}

struct NotificationsStackView: View {
    @ObservedObject var store: NotificationsStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.notifications) { item in
                NotificationToastView(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Chrome icon rendered from bundled `Resources/chrome.png`.
/// Used in both the collapsed pill and expanded panel (when there's no album artwork).
struct ChromeIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let fallbackSystemName: String

    var body: some View {
        if let url = Bundle.module.url(forResource: "chrome", withExtension: "png"),
           let chromeImg = NSImage(contentsOf: url) {
            Image(nsImage: chromeImg)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct SoundVisualizerView: View {
    let isPlaying: Bool
    let baseColor: Color
    private let barCount = 10

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

                ZStack(alignment: .trailing) {
                    // Bars grow around a fixed vertical center (no bottom pivot).
                    HStack(alignment: .center, spacing: spacing) {
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
                                .fill(baseColor.opacity(isPlaying ? 0.98 : 0.35))
                                .frame(width: barWidth, height: height)
                        }
                    }
                    // Hard constrain bars to the emitWidth so the left half stays empty.
                    .frame(width: emitWidth, alignment: .trailing)
                }
                .frame(width: width, height: geo.size.height, alignment: .trailing)
            }
        }
        .clipped()
    }
}

struct IslandView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var islandState: IslandState
    @ObservedObject var notifications: NotificationsStore
    @Namespace private var pillNamespace

    var body: some View {
        VStack(spacing: 10) {
            if islandState.expanded {
                VStack(spacing: 8) {
                    NotificationsStackView(store: notifications)
                        .padding(.horizontal, 12)

                    HStack(alignment: .center, spacing: 10) {
                        if let img = nowPlaying.artworkImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        } else {
                            if isChrome {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                    ChromeIconView(size: 28, cornerRadius: 10, fallbackSystemName: iconName)
                                }
                                .frame(width: 40, height: 40)
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .frame(width: 40, height: 40)
                            }
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
                    .padding(.bottom, 8)
                }
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
                                .frame(width: 27, height: 27)
                            if let album = nowPlaying.session?.album,
                               !album.isEmpty,
                               let img = nowPlaying.artworkImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 27, height: 27)
                                    .clipShape(Circle())
                            } else {
                                if isChrome {
                                    ChromeIconView(size: 22, cornerRadius: 999, fallbackSystemName: iconName)
                                } else {
                                    Image(systemName: iconName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        // Right: soundwaves indicator
                        SoundVisualizerView(
                            isPlaying: nowPlaying.session?.playback == .playing,
                            baseColor: Color(nsColor: nowPlaying.waveformAccentColor ?? .white)
                        )
                            .frame(width: 70, height: 16, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 315, height: 35)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 0)
        .background(Color.clear)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: islandState.expanded)
    }

    private var title: String {
        nowPlaying.session?.title ?? "Nothing playing"
    }

    private var subtitle: String? {
        nowPlaying.session?.subtitle ?? "Spotify / Chrome"
    }

    private var isChrome: Bool {
        let subtitle = nowPlaying.session?.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (nowPlaying.session?.source == .chrome) || (subtitle?.range(of: "Chrome", options: .caseInsensitive) != nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 50),
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
        // Keep the window as small as possible so it doesn't block clicks in other apps,
        // while animating the size/position for a smoother pill <-> expanded transition.
        isExpanded = expanded
        hosting.hitTestBandHeight = expanded ? 160 : 72

        let targetSize = expanded
        ? NSSize(width: 520, height: 120)
        : NSSize(width: 380, height: 56)

        let nextFrame = topCenterFrame(size: targetSize, expanded: expanded)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    private func topCenterFrame(size: NSSize, expanded: Bool) -> NSRect {
        guard let screen = NSScreen.main else { return panel.frame }
        let frame = screen.frame
        let x = frame.minX + (frame.width - size.width) / 2
        // Nudge down so expanded sits below the notch while pill stays closer to original.
        let yNudge: CGFloat = expanded ? 50 : 4
        let y = frame.maxY - size.height - yNudge
        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
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
        let yNudge: CGFloat = isExpanded ? 50 : 0
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
    private let notifications = NotificationsStore()
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

        controller.setRootView(IslandView(nowPlaying: nowPlaying, islandState: islandState, notifications: notifications))
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
