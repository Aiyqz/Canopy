import SwiftUI

/// The desktop "lockscreen" widget content. Rendered over a Liquid Glass
/// background (see WidgetView) with a gradient tinted from album art.
struct WidgetContent: View {
    @ObservedObject var vm: NowPlayingModel
    var preset: WidgetPreset

    var body: some View {
        switch preset {
        case .lockscreen: lockscreen
        case .nowPlaying: nowPlaying
        case .lyrics:     lyricsLayout
        case .minimal:    minimal
        }
    }

    // MARK: Lockscreen (iOS style)

    private var lockscreen: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 26)

            ClockView()
                .padding(.top, 6)

            Spacer()

            if vm.hasMedia {
                NowPlayingCard(vm: vm)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 22)
            } else {
                Text("Not Playing")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Now Playing (art-forward)

    private var nowPlaying: some View {
        VStack(spacing: 16) {
            Artwork(image: vm.artwork, size: 200, corner: 18)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .padding(.top, 26)

            VStack(spacing: 4) {
                Text(vm.hasMedia ? vm.title : "Nothing Playing")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(vm.hasMedia ? vm.artist : "Canopy")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)

            ScrubBar(vm: vm, accent: vm.palette.first ?? .white)
                .padding(.horizontal, 26)

            TransportControls(vm: vm)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Lyrics-forward

    private var lyricsLayout: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Artwork(image: vm.artwork, size: 48, corner: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.hasMedia ? vm.title : "Nothing Playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(vm.hasMedia ? vm.artist : "Canopy")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)

            LyricsColumn(vm: vm)
                .frame(maxHeight: .infinity)

            TransportControls(vm: vm)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Minimal

    private var minimal: some View {
        ClockView(emphasizeSeconds: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Clock

struct ClockView: View {
    var emphasizeSeconds = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        // Honour the user's 12/24-hour preference, but keep the big clock clean
        // (no AM/PM), matching the iOS lock screen.
        let uses24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?
            .contains("a") ?? false)
        f.dateFormat = uses24h ? "H:mm" : "h:mm"
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        // Localized weekday + month order (e.g. "Monday, June 8" / "lundi 8 juin").
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 2) {
                Text(Self.dateFmt.string(from: ctx.date))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(Self.timeFmt.string(from: ctx.date))
                    .font(.system(size: 74, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Now Playing card (used in lockscreen)

struct NowPlayingCard: View {
    @ObservedObject var vm: NowPlayingModel

    var body: some View {
        VStack(spacing: 12) {
            if let lyric = vm.currentLyric {
                Text(lyric)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .id(lyric)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 12) {
                Artwork(image: vm.artwork, size: 44, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(vm.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
            }

            ScrubBar(vm: vm, accent: vm.palette.first ?? .white)
            TransportControls(vm: vm, compact: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Transport controls

struct TransportControls: View {
    @ObservedObject var vm: NowPlayingModel
    var compact = false

    private var big: CGFloat { compact ? 22 : 30 }
    private var small: CGFloat { compact ? 15 : 20 }

    var body: some View {
        HStack(spacing: compact ? 30 : 40) {
            glyph("backward.fill", small, "Previous track") { vm.previous() }
            glyph(vm.isPlaying ? "pause.fill" : "play.fill", big,
                  vm.isPlaying ? "Pause" : "Play") { vm.togglePlayPause() }
            glyph("forward.fill", small, "Next track") { vm.next() }
        }
        .disabled(!vm.hasMedia)
        .opacity(vm.hasMedia ? 1 : 0.4)
    }

    private func glyph(_ name: String, _ size: CGFloat, _ label: String,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Lyrics column

struct LyricsColumn: View {
    @ObservedObject var vm: NowPlayingModel

    var body: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if vm.lyrics.isEmpty {
                            Text(vm.hasMedia ? "Searching for synced lyrics…" : "Nothing playing")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.top, 20)
                        }
                        ForEach(Array(vm.lyrics.enumerated()), id: \.element.id) { idx, line in
                            Button {
                                vm.seek(toTime: line.time)
                            } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: isCurrent(idx) ? 19 : 15,
                                                   weight: isCurrent(idx) ? .bold : .medium))
                                    .foregroundStyle(foreground(idx))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                            .animation(.easeInOut(duration: 0.25), value: vm.currentLyricIndex)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .onChange(of: vm.currentLyricIndex) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private func isCurrent(_ idx: Int) -> Bool { idx == vm.currentLyricIndex }

    private func foreground(_ idx: Int) -> AnyShapeStyle {
        if isCurrent(idx) {
            let colors = vm.palette.count >= 2 ? Array(vm.palette.prefix(2)) : [.white, .white]
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
        if let cur = vm.currentLyricIndex, idx < cur {
            return AnyShapeStyle(Color.white.opacity(0.35))
        }
        return AnyShapeStyle(Color.white.opacity(0.55))
    }
}
