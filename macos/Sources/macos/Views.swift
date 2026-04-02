import SwiftUI

struct SourceIconView: View {
    let source: NowPlayingSource
    let size: CGFloat
    let cornerRadius: CGFloat

    private var resourceInfo: (name: String, ext: String)? {
        switch source {
        case .browser(let name) where name == "Google Chrome":
            return ("chrome", "png")
        case .browser(let name) where name == "Arc":
            return ("arc", "png")
        case .spotify: return ("spotify", "png")
        case .appleMusic: return ("applemusic", "jpg")
        default: return nil
        }
    }

    private var fallbackIcon: String {
        switch source {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .appleMusic: return "music.note"
        case .browser: return "globe"
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

struct IslandView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var islandState: IslandState
    @ObservedObject var notifications: NotificationsStore
    @Namespace private var pillNamespace

    var body: some View {
        VStack(spacing: 10) {
            if islandState.expanded {
                expandedPanel
            } else {
                collapsedPill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 0)
        .background(Color.clear)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: islandState.expanded)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: nowPlaying.session != nil)
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 8) {
            NotificationsStackView(store: notifications)
                .padding(.horizontal, 12)

            HStack(alignment: .center, spacing: 10) {
                artworkView

                Text(condensedNowPlayingLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 0)

                outputDeviceMenu
                sourceSwitchButtons
                mediaControls
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
    }

    @ViewBuilder
    private var artworkView: some View {
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
    }

    @ViewBuilder
    private var outputDeviceMenu: some View {
        if !nowPlaying.outputDevices.isEmpty {
            Menu {
                ForEach(nowPlaying.outputDevices) { device in
                    Button {
                        nowPlaying.switchOutputDevice(to: device.id)
                    } label: {
                        HStack(spacing: 8) {
                            if device.isDefault {
                                Image(systemName: "checkmark")
                            }
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(defaultOutputDeviceName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 135, alignment: .leading)
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    @ViewBuilder
    private var sourceSwitchButtons: some View {
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
    }

    @ViewBuilder
    private var mediaControls: some View {
        let isBrowser: Bool = {
            if case .browser = nowPlaying.session?.source { return true }
            return false
        }()
        let canUse = nowPlaying.session?.source == .spotify
            || nowPlaying.session?.source == .appleMusic
            || isBrowser

        if canUse {
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
            }
        }
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        let hasSession = nowPlaying.session != nil

        return Button {
            guard hasSession else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
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

    // MARK: - Helpers

    private var condensedNowPlayingLine: String {
        let t = nowPlaying.session?.title ?? "Nothing playing"
        var parts: [String] = [t]
        if let artist = nowPlaying.session?.subtitle, !artist.isEmpty {
            parts.append(artist)
        }
        return parts.joined(separator: " • ")
    }

    private var defaultOutputDeviceName: String {
        nowPlaying.outputDevices.first(where: \.isDefault)?.name ?? "Output"
    }
}
