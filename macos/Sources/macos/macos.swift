import AppKit
import Foundation
import Combine
import SwiftUI

/// Posts macOS system media-key events (aux control buttons) so the OS routes them
/// through the standard Media Session pipeline (e.g. Chrome/YouTube reacts like a real
/// hardware media key press).
final class MediaKeySender {
    // hidsystem/ev_keymap.h
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
                // Post via HID event tap so the OS interprets it like a real media key.
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

enum NowPlayingSource: String {
    case spotify
    case appleMusic
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
          set tArtworkURL to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
          end try
          try
            set tArtworkURL to artwork url of current track
          end try
          return pState & "||" & tName & "||" & tArtist & "||" & tArtworkURL
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURLString = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard state == "playing" || state == "paused" else { return nil }
        guard !title.isEmpty else { return nil }

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        let artworkURL = artworkURLString.isEmpty ? nil : URL(string: artworkURLString)
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
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

final class AppleMusicNowPlayingProvider {
    private let runner = AppleScriptRunner()
    private var lastArtworkTrack: String?
    private var cachedArtworkURL: URL?

    func fetch() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return ""
        end tell
        tell application "Music"
          if player state is stopped then return ""
          set pState to "playing"
          if player state is paused then set pState to "paused"
          set tName to ""
          set tArtist to ""
          set tAlbum to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
          end try
          return pState & "||" & tName & "||" & tArtist & "||" & tAlbum
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard state == "playing" || state == "paused" else { return nil }
        guard !title.isEmpty else { return nil }

        let trackKey = "\(title)—\(artist)"
        if trackKey != lastArtworkTrack {
            lastArtworkTrack = trackKey
            cachedArtworkURL = lookupArtworkURL(title: title, artist: artist, album: album)
        }

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: cachedArtworkURL,
            source: .appleMusic,
            playback: playback,
            canPlayPause: true
        )
    }

    private func sanitizeForSearch(_ text: String) -> String {
        text.replacingOccurrences(of: "$", with: "S")
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: "*", with: "")
    }

    private func lookupArtworkURL(title: String, artist: String, album: String) -> URL? {
        let cleanArtist = sanitizeForSearch(artist)
        var queries = ["\(title) \(cleanArtist)"]
        if !album.isEmpty { queries.append("\(album) \(cleanArtist)") }
        queries.append(title)

        for q in queries {
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=5") else {
                continue
            }
            guard let data = try? Data(contentsOf: searchURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty else {
                continue
            }
            let match = results.first(where: {
                let a = ($0["artistName"] as? String ?? "").lowercased()
                return a.contains(artist.components(separatedBy: " ").first?.lowercased() ?? "")
            }) ?? results.first
            if let artworkStr = match?["artworkUrl100"] as? String {
                let highRes = artworkStr.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                return URL(string: highRes)
            }
        }
        return nil
    }

    func togglePlayPause() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to playpause
        """
        _ = try? runner.run(script)
    }

    func previousTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to previous track
        """
        _ = try? runner.run(script)
    }

    func nextTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to next track
        """
        _ = try? runner.run(script)
    }
}

final class ChromeNowPlayingProvider {
    private let runner = AppleScriptRunner()
    private(set) var mediaTabURL: String?

    private let mediaJS = """
    (function() {
      var state = 'none', title = '', artist = '', artwork = '';
      try {
        var ms = navigator.mediaSession;
        if (ms && ms.playbackState === 'playing') state = 'playing';
        else if (ms && ms.playbackState === 'paused') state = 'paused';
        if (ms && ms.metadata) {
          title = ms.metadata.title || '';
          artist = ms.metadata.artist || '';
        }
      } catch(e) {}
      try {
        var md = navigator.mediaSession && navigator.mediaSession.metadata;
        if (md && md.artwork && md.artwork.length > 0) artwork = md.artwork[md.artwork.length - 1].src || '';
      } catch(e) {}
      if (state === 'none') {
        var elems = document.querySelectorAll('video, audio');
        for (var i = 0; i < elems.length; i++) {
          var e = elems[i];
          if (e.muted || e.volume === 0) continue;
          if (!e.paused && e.currentTime > 0) { state = 'playing'; break; }
          if (e.paused && e.currentTime > 0 && state !== 'playing') state = 'paused';
        }
      }
      if (state === 'none' && location.host === 'open.spotify.com') {
        var btn = document.querySelector('[data-testid="control-button-playpause"]');
        if (btn) {
          var lbl = (btn.getAttribute('aria-label') || '').toLowerCase();
          if (lbl.indexOf('pause') !== -1) state = 'playing';
          else if (lbl.indexOf('play') !== -1) state = 'paused';
        }
      }
      if (state === 'none' && title) state = 'paused';
      if (!title) title = document.title || '';
      return state + '||' + title + '||' + artist + '||' + artwork + '||' + location.href;
    })();
    """

    func fetchActiveTabTitle() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Google Chrome" then return ""
        end tell
        tell application "Google Chrome"
          if (count of windows) is 0 then return ""
          set jsCode to "\(mediaJS)"

          set bestPaused to ""

          -- 1. Try the active tab first (fast path for playing).
          try
            set jr to (execute active tab of front window javascript jsCode)
            if jr starts with "playing" then return jr
            if jr starts with "paused" and bestPaused is "" then set bestPaused to jr
          end try

          -- 2. Scan background tabs on known media domains.
          --    A "playing" tab always wins; otherwise keep first "paused".
          repeat with t in tabs of front window
            set tURL to URL of t
            if tURL contains "open.spotify.com" or tURL contains "youtube.com" or tURL contains "music.youtube.com" or tURL contains "netflix.com" or tURL contains "twitch.tv" or tURL contains "soundcloud.com" then
              try
                set jr to (execute t javascript jsCode)
                if jr starts with "playing" then return jr
                if bestPaused is "" and jr starts with "paused" then set bestPaused to jr
              end try
            end if
          end repeat

          return bestPaused
        end tell
        """

        guard let result = try? runner.run(script).trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }

        let parts = result.components(separatedBy: "||")
        let state = parts.first ?? "none"
        guard state == "playing" || state == "paused" else { return nil }

        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkStr = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tabURL = (parts.count > 4 ? parts[4] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = artworkStr.isEmpty ? nil : URL(string: artworkStr)
        let playback: PlaybackState = (state == "playing") ? .playing : .paused

        if !tabURL.isEmpty { mediaTabURL = tabURL }

        return AudioSession(
            title: title.isEmpty ? "Chrome" : title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: artworkURL,
            source: .chrome,
            playback: playback,
            canPlayPause: true
        )
    }

    private var mediaTabDomain: String? {
        guard let url = mediaTabURL, let host = URL(string: url)?.host else { return nil }
        return host
    }

    private func runOnMediaTab(js: String) {
        guard let domain = mediaTabDomain else { return }
        let script = """
        tell application "Google Chrome"
          if (count of windows) is 0 then return
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t contains "\(domain)" then
                execute t javascript "\(js)"
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        """
        _ = try? runner.run(script)
    }

    func togglePlayPause() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='play'||l==='pause'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){if(m.paused){m.play()}else{m.pause()};return 'media'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func previousTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='previous'||l==='skip back'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=Math.max(0,m.currentTime-10);return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func nextTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='next'||l==='skip forward'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=m.currentTime+10;return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }
}

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var session: AudioSession? = nil
    @Published private(set) var artworkImage: NSImage? = nil
    @Published private(set) var waveformAccentColor: NSColor? = nil
    @Published private(set) var availableSources: [AudioSession] = []
    private var pinnedSource: NowPlayingSource? = nil

    private let spotify = SpotifyNowPlayingProvider()
    private let appleMusic = AppleMusicNowPlayingProvider()
    private let chrome = ChromeNowPlayingProvider()
    private let mediaKeys = MediaKeySender()
    private var timer: Timer?
    private var currentArtworkURL: URL? = nil
    private var nilCycles = 0
    private let nilGrace = 1 // keep session alive for 8 × 0.6 s ≈ 4.8 s during track transitions

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let spotifySession = self.spotify.fetch()
            let appleMusicSession = self.appleMusic.fetch()
            let chromeSession = self.chrome.fetchActiveTabTitle()

            var sources: [AudioSession] = []
            if let s = spotifySession { sources.append(s) }
            if let a = appleMusicSession { sources.append(a) }
            if let c = chromeSession { sources.append(c) }
            self.availableSources = sources

            let next: AudioSession?
            if let pinned = self.pinnedSource,
               let match = sources.first(where: { $0.source == pinned }) {
                next = match
            } else if let playing = sources.first(where: { $0.playback == .playing }) {
                next = playing
            } else if let current = self.session?.source,
                      let match = sources.first(where: { $0.source == current }) {
                next = match
            } else {
                next = sources.first
            }

            if let next {
                self.nilCycles = 0
                if next != self.session {
                    self.session = next
                    self.refreshArtworkIfNeeded(for: next)
                }
            } else if self.session != nil {
                self.nilCycles += 1
                guard self.nilCycles >= self.nilGrace else { return }
                self.session = nil
                self.currentArtworkURL = nil
                self.artworkImage = nil
                self.waveformAccentColor = nil
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func togglePlayPauseIfSupported() {
        guard session?.canPlayPause == true else { return }
        switch session?.source {
        case .chrome: chrome.togglePlayPause()
        case .spotify: spotify.togglePlayPause()
        case .appleMusic: appleMusic.togglePlayPause()
        default: break
        }
        if var s = session {
            s.playback = (s.playback == .playing) ? .paused : .playing
            session = s
        }
    }

    func previousTrackIfSupported() {
        switch session?.source {
        case .chrome: chrome.previousTrack()
        case .spotify: spotify.previousTrack()
        case .appleMusic: appleMusic.previousTrack()
        default: break
        }
    }

    func nextTrackIfSupported() {
        switch session?.source {
        case .chrome: chrome.nextTrack()
        case .spotify: spotify.nextTrack()
        case .appleMusic: appleMusic.nextTrack()
        default: break
        }
    }

    func switchSource(to source: NowPlayingSource) {
        pinnedSource = source
        if let match = availableSources.first(where: { $0.source == source }) {
            session = match
            refreshArtworkIfNeeded(for: match)
        }
    }

    private func refreshArtworkIfNeeded(for session: AudioSession) {
        guard let url = session.artworkURL else {
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
                guard self.currentArtworkURL == urlCopy else { return }
                let image = NSImage(data: data)
                self.artworkImage = image
                self.waveformAccentColor = image.map(self.averageAccentColor(from:))
            } catch {}
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

/// Captures system audio via ScreenCaptureKit and publishes a smoothed RMS
/// level (0…1) that drives the sound visualizer bars.
@MainActor

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

struct SourceIconView: View {
    let source: NowPlayingSource
    let size: CGFloat
    let cornerRadius: CGFloat

    private var resourceInfo: (name: String, ext: String)? {
        switch source {
        case .chrome: return ("chrome", "png")
        case .spotify: return ("spotify", "png")
        case .appleMusic: return ("applemusic", "jpg")
        case .unknown: return nil
        }
    }

    private var fallbackIcon: String {
        switch source {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .appleMusic: return "music.note"
        case .chrome: return "globe"
        case .unknown: return "music.note"
        }
    }

    var body: some View {
        if let info = resourceInfo,
           let url = Bundle.module.url(forResource: info.name, withExtension: info.ext),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
        }
    }
}

struct SoundVisualizerView: View {
    let isPlaying: Bool
    let baseColor: Color
    private let barCount = 10

    private func fract(_ x: Double) -> Double { x - floor(x) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let emitWidth = width / 2
            let spacing: CGFloat = 1.05
            let barWidth = max(1, (emitWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let maxBarHeight: CGFloat = geo.size.height * 0.85

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let frame = floor(t * 38)

                ZStack(alignment: .trailing) {
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
                            let height = maxBarHeight * (0.10 + 0.90 * mix) * (isPlaying ? 1.0 : 0.0)

                            RoundedRectangle(cornerRadius: max(1, barWidth * 0.2), style: .continuous)
                                .fill(baseColor.opacity(isPlaying ? 0.98 : 0.0))
                                .frame(width: barWidth, height: height)
                        }
                    }
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
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                SourceIconView(source: nowPlaying.session?.source ?? .unknown, size: 28, cornerRadius: 6)
                            }
                            .frame(width: 40, height: 40)
                        }

                        Text(condensedNowPlayingLine)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if nowPlaying.availableSources.count > 1 {
                            let others = nowPlaying.availableSources.filter { $0.source != nowPlaying.session?.source }
                            ForEach(others.indices, id: \.self) { idx in
                                let other = others[idx]
                                Button {
                                    nowPlaying.switchSource(to: other.source)
                                } label: {
                                    SourceIconView(source: other.source, size: 20, cornerRadius: 4)
                                }
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                            }
                        }

                        let canUseMediaControls = nowPlaying.session?.source == .spotify || nowPlaying.session?.source == .appleMusic || nowPlaying.session?.source == .chrome

                        if canUseMediaControls {
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
                                    Image(systemName: "play.fill")
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
                let hasSession = nowPlaying.session != nil

                Button {
                    guard hasSession else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        islandState.expanded = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 27, height: 27)
                            if let img = nowPlaying.artworkImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 27, height: 27)
                                    .clipShape(Circle())
                            } else {
                                SourceIconView(source: nowPlaying.session?.source ?? .unknown, size: 22, cornerRadius: 999)
                            }
                        }
                        .opacity(hasSession ? 1 : 0)

                        Spacer(minLength: 0)

                        SoundVisualizerView(
                            isPlaying: nowPlaying.session?.playback == .playing,
                            baseColor: Color(nsColor: nowPlaying.waveformAccentColor ?? .white)
                        )
                        .frame(width: 70, height: 16, alignment: .trailing)
                        .opacity(hasSession ? 1 : 0)
                    }
                    .padding(.horizontal, hasSession ? 12 : 0)
                    .frame(width: hasSession ? 315 : 170, height: hasSession ? 38 : 32)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.black)
                            .matchedGeometryEffect(id: "pill", in: pillNamespace)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(hasSession ? 0.08 : 0.0), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(hasSession ? 0.35 : 0.0), radius: 18, y: 10)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: nowPlaying.session != nil)
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

        return parts.joined(separator: " • ")
    }

}

@MainActor
final class IslandPanelController {
    private let panel: NSPanel
    private var isClickThroughEnabled = false
    private let hosting: PassthroughHostingView<AnyView>
    private(set) var isExpanded: Bool = false
    private(set) var hasSession: Bool = false

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

    func setHasSession(_ value: Bool) {
        hasSession = value
        guard !isExpanded else { return }

        let targetSize = value
            ? NSSize(width: 380, height: 56)
            : NSSize(width: 200, height: 44)
        hosting.hitTestBandHeight = value ? 72 : 44

        let nextFrame = topCenterFrame(size: targetSize, expanded: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded

        let targetSize: NSSize
        if expanded {
            hosting.hitTestBandHeight = 160
            targetSize = NSSize(width: 520, height: 120)
        } else if hasSession {
            hosting.hitTestBandHeight = 72
            targetSize = NSSize(width: 380, height: 56)
        } else {
            hosting.hitTestBandHeight = 44
            targetSize = NSSize(width: 200, height: 44)
        }

        let nextFrame = topCenterFrame(size: targetSize, expanded: expanded)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? 0.25 : 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    private func topCenterFrame(size: NSSize, expanded: Bool) -> NSRect {
        guard let screen = NSScreen.main else { return panel.frame }
        let frame = screen.frame
        let x = frame.minX + (frame.width - size.width) / 2
        let yNudge: CGFloat = expanded ? 50 : 0
        let y = frame.maxY - size.height - yNudge
        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    private func positionTopCenter() {
        let frame = topCenterFrame(size: panel.frame.size, expanded: isExpanded)
        panel.setFrameOrigin(frame.origin)
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

        // Shrink the panel to notch size when no audio session is active.
        nowPlaying.$session
            .receive(on: RunLoop.main)
            .sink { [weak controller] session in
                controller?.setHasSession(session != nil)
            }
            .store(in: &cancellables)

        // Collapse when switching macOS desktop spaces.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.islandState.expanded else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    self.islandState.expanded = false
                }
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
