import AppKit
import Foundation
import Combine
import CoreAudio

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var session: AudioSession? = nil
    @Published private(set) var artworkImage: NSImage? = nil
    @Published private(set) var waveformAccentColor: NSColor? = nil
    @Published private(set) var availableSources: [AudioSession] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    private var pinnedSource: NowPlayingSource? = nil

    private let spotify = SpotifyNowPlayingProvider()
    private let appleMusic = AppleMusicNowPlayingProvider()
    private let browsers: [BrowserProvider] = [
        BrowserProvider(browserName: "Google Chrome"),
        BrowserProvider(browserName: "Arc"),
        BrowserProvider(browserName: "Brave Browser"),
        BrowserProvider(browserName: "Microsoft Edge"),
        BrowserProvider(browserName: "Vivaldi"),
        BrowserProvider(browserName: "Opera"),
    ]
    private let mediaKeys = MediaKeySender()
    private var timer: Timer?
    private var currentArtworkURL: URL? = nil
    private var nilCycles = 0
    private let nilGrace = 1

    private var isPolling = false
    private var browserTimeoutCooldownUntil: [String: Date] = [:]

    private let processChecker = AppleScriptRunner()
    private let outputDeviceService = AudioOutputDeviceService()
    private var lastOutputRefreshAt = Date.distantPast

    private func browserProvider(for source: NowPlayingSource) -> BrowserProvider? {
        guard case .browser(let name) = source else { return nil }
        return browsers.first { $0.browserName == name }
    }

    private func runningProcessNames() -> Set<String> {
        let script = """
        tell application "System Events"
          set pNames to name of every process
          set AppleScript's text item delimiters to "||"
          return pNames as text
        end tell
        """
        guard let raw = try? processChecker.run(script) else { return [] }
        return Set(raw.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func fetchWithTimeout<T>(_ timeout: TimeInterval, _ work: @escaping () -> T?) -> (T?, Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T? = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            lock.lock()
            result = r
            lock.unlock()
            semaphore.signal()
        }

        let didTimeout = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if didTimeout { return (nil, true) }

        lock.lock()
        let r = result
        lock.unlock()
        return (r, false)
    }

    func start() {
        stop()
        refreshOutputDevices()
        lastOutputRefreshAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.isPolling else { return }

            if Date().timeIntervalSince(self.lastOutputRefreshAt) >= 2.0 {
                self.refreshOutputDevices()
                self.lastOutputRefreshAt = Date()
            }

            self.isPolling = true
            let running = self.runningProcessNames()
            let cooldownSnapshot = self.browserTimeoutCooldownUntil
            let now = Date()

            let spotifyProvider = self.spotify
            let appleMusicProvider = self.appleMusic
            let browsers = self.browsers

            DispatchQueue.global(qos: .userInitiated).async {
                var sources: [AudioSession] = []
                var timedOutBrowsers: [String] = []
                let isCurrentSpotify = self.session?.source == .spotify
                let isCurrentAppleMusic = self.session?.source == .appleMusic

                if running.contains("Spotify") {
                    let (s, _) = self.fetchWithTimeout(isCurrentSpotify ? 0.25 : 0.2) { spotifyProvider.fetch() }
                    if let s { sources.append(s) }
                }
                if running.contains("Music") {
                    let (a, _) = self.fetchWithTimeout(isCurrentAppleMusic ? 0.25 : 0.2) { appleMusicProvider.fetch() }
                    if let a { sources.append(a) }
                }

                for browser in browsers where running.contains(browser.processName) {
                    if let until = cooldownSnapshot[browser.browserName], until > now {
                        continue
                    }

                    let isCurrentBrowser = {
                        if case .browser(let name) = self.session?.source { return name == browser.browserName }
                        return false
                    }()
                    let (session, didTimeout) = browser.fetchWithTimeout(isCurrentBrowser ? 0.35 : 0.22)
                    if didTimeout {
                        timedOutBrowsers.append(browser.browserName)
                        continue
                    }
                    if let session {
                        sources.append(session)
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

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
                        if self.nilCycles >= self.nilGrace {
                            self.session = nil
                            self.currentArtworkURL = nil
                            self.artworkImage = nil
                            self.waveformAccentColor = nil
                        }
                    }

                    let cooldownSeconds: TimeInterval = 6
                    for name in timedOutBrowsers {
                        self.browserTimeoutCooldownUntil[name] = Date().addingTimeInterval(cooldownSeconds)
                    }

                    self.isPolling = false
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func togglePlayPauseIfSupported() {
        guard session?.canPlayPause == true, let source = session?.source else { return }
        switch source {
        case .spotify: spotify.togglePlayPause()
        case .appleMusic: appleMusic.togglePlayPause()
        case .browser:
            if let provider = browserProvider(for: source) {
                DispatchQueue.global(qos: .userInitiated).async {
                    provider.togglePlayPause()
                }
            }
        case .unknown: break
        }
        if var s = session {
            s.playback = (s.playback == .playing) ? .paused : .playing
            session = s
        }
    }

    func previousTrackIfSupported() {
        guard let source = session?.source else { return }
        switch source {
        case .spotify: spotify.previousTrack()
        case .appleMusic: appleMusic.previousTrack()
        case .browser:
            if let provider = browserProvider(for: source) {
                DispatchQueue.global(qos: .userInitiated).async {
                    provider.previousTrack()
                }
            }
        case .unknown: break
        }
    }

    func nextTrackIfSupported() {
        guard let source = session?.source else { return }
        switch source {
        case .spotify: spotify.nextTrack()
        case .appleMusic: appleMusic.nextTrack()
        case .browser:
            if let provider = browserProvider(for: source) {
                DispatchQueue.global(qos: .userInitiated).async {
                    provider.nextTrack()
                }
            }
        case .unknown: break
        }
    }

    func switchSource(to source: NowPlayingSource) {
        pinnedSource = source
        if let match = availableSources.first(where: { $0.source == source }) {
            session = match
            refreshArtworkIfNeeded(for: match)
        }
    }

    func switchOutputDevice(to deviceID: AudioDeviceID) {
        guard outputDeviceService.setDefaultOutputDevice(deviceID) else { return }
        refreshOutputDevices()
    }

    private func refreshOutputDevices() {
        outputDevices = outputDeviceService.fetchOutputDevices()
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

        let width: Int = 32
        let height: Int = 32
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .white
        }

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

        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(ptr[offset + 0])
            let g = Double(ptr[offset + 1])
            let b = Double(ptr[offset + 2])
            let a = Double(ptr[offset + 3]) / 255.0

            guard a > 0.1 else { continue }

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
