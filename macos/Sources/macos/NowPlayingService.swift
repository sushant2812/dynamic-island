import AppKit
import Foundation
import Combine

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
    private let nilGrace = 1

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
