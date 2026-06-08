import SwiftUI
import UniformTypeIdentifiers

/// The root view that fills the floating notch window. Hover (or an active file
/// drop) swaps between the collapsed pill and the expanded media panel.
/// Preference key the expanded panel uses to report its natural height so the
/// notch window can morph to fit its content (no clipping, Dynamic-Island style).
struct ExpandedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    @ObservedObject var vm: NowPlayingModel
    @ObservedObject var settings: SettingsStore
    let metrics: NotchMetrics
    let onPresent: (NotchPresentation) -> Void
    var onExpandedHeight: (CGFloat) -> Void = { _ in }

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: NotchPresentation {
        if hovering || vm.shelfPinned { return .expanded }
        if vm.bannerActive { return .banner }
        return .collapsed
    }

    private var isOpen: Bool { presentation != .collapsed }

    var body: some View {
        ZStack(alignment: .top) {
            switch presentation {
            case .expanded:
                ExpandedPanel(vm: vm, scale: settings.notchSize.contentScale)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ExpandedHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            case .banner:
                if let banner = vm.currentBanner {
                    BannerView(banner: banner)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            case .collapsed:
                CollapsedPill(vm: vm, metrics: metrics)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                // Always solid black so the island reads as an extension of the
                // physical notch.
                NotchShape().fill(.black)
                if isOpen, settings.hoverStyle == .subtleGradient {
                    // A faint light sheen over the black — still dark, just a hint
                    // of dimension. (Not the album-color tint, which floated.)
                    NotchShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.03),
                                    Color.clear
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
            }
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 20, y: 10)
        )
        .overlay(
            NotchShape().stroke(Color.white.opacity(isOpen ? 0.10 : 0), lineWidth: 0.5)
        )
        .overlay(dropHint)
        .contentShape(NotchShape())
        .onHover { hovering = $0; onPresent(presentation) }
        .onChange(of: vm.shelfPinned) { _, _ in onPresent(presentation) }
        .onChange(of: vm.bannerActive) { _, _ in onPresent(presentation) }
        .onChange(of: vm.currentBanner) { _, _ in onPresent(presentation) }
        .onTapGesture { if presentation == .banner { vm.dismissBanner() } }
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            handleDrop(providers)
            return true
        }
        .onPreferenceChange(ExpandedHeightKey.self) { height in
            if height > 1 { onExpandedHeight(height) }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82),
                   value: presentation)
    }

    private var dropBinding: Binding<Bool> {
        Binding(get: { vm.isDropTargeted }, set: { vm.isDropTargeted = $0 })
    }

    @ViewBuilder private var dropHint: some View {
        if vm.isDropTargeted {
            NotchShape()
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(4)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                // Only accept real on-disk file URLs.
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { vm.addFiles([url]) }
            }
        }
    }
}

// MARK: - Collapsed

struct CollapsedPill: View {
    @ObservedObject var vm: NowPlayingModel
    let metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            if vm.hasMedia {
                Artwork(image: vm.artwork, size: metrics.notchHeight - 10, corner: 5)
                    .padding(.leading, 8)
            }
            Spacer(minLength: metrics.notchWidth)
            if vm.hasMedia {
                EqualizerBars(active: vm.isPlaying)
                    .padding(.trailing, 12)
            }
        }
        .frame(height: metrics.notchHeight)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Banner

struct BannerView: View {
    let banner: NotchBanner

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let secondary = banner.subtitle ?? banner.body, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if banner.kind == .nowPlaying {
                EqualizerBars(active: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var icon: some View {
        if let image = banner.icon {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: banner.kind == .nowPlaying ? "music.note" : "bell.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedPanel: View {
    @ObservedObject var vm: NowPlayingModel
    var scale: CGFloat = 1

    private var accent: Color { vm.palette.first ?? .white }
    private func s(_ x: CGFloat) -> CGFloat { x * scale }

    var body: some View {
        VStack(spacing: s(10)) {
            HStack(spacing: s(12)) {
                Artwork(image: vm.artwork, size: s(52), corner: s(10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.hasMedia ? vm.title : "Nothing Playing")
                        .font(.system(size: s(13), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(vm.hasMedia ? vm.artist : "Canopy")
                        .font(.system(size: s(11)))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerBars(active: vm.isPlaying, color: .white.opacity(0.85))
            }

            if let lyric = vm.currentLyric {
                Text(lyric)
                    .font(.system(size: s(12), weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: lyricColors, startPoint: .leading, endPoint: .trailing)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(lyric)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
            }

            ScrubBar(vm: vm, accent: accent)

            HStack(spacing: s(28)) {
                ControlButton(system: "backward.fill", size: s(16), label: "Previous track") { vm.previous() }
                ControlButton(system: vm.isPlaying ? "pause.fill" : "play.fill", size: s(22),
                              label: vm.isPlaying ? "Pause" : "Play") { vm.togglePlayPause() }
                ControlButton(system: "forward.fill", size: s(16), label: "Next track") { vm.next() }
            }
            .disabled(!vm.hasMedia)
            .opacity(vm.hasMedia ? 1 : 0.4)

            if !vm.shelfFiles.isEmpty {
                ShelfStrip(vm: vm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, s(18))
        .padding(.top, s(14))
        .padding(.bottom, s(12))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var lyricColors: [Color] {
        let p = vm.palette.map { $0.opacity(1) }
        return p.count >= 2 ? Array(p.prefix(2)) : [.white, .white.opacity(0.8)]
    }
}

// MARK: - Scrub bar

struct ScrubBar: View {
    @ObservedObject var vm: NowPlayingModel
    var accent: Color

    @State private var dragging = false
    @State private var dragFraction: Double = 0

    var body: some View {
        // Drive the fill from the live (elapsed + timestamp)-projected position so
        // it advances smoothly between backend updates. Pause the ticking while
        // stopped or scrubbing to avoid needless redraws.
        TimelineView(.animation(minimumInterval: 0.2, paused: !vm.isPlaying || dragging)) { context in
            let live = vm.liveElapsed(at: context.date)
            let currentFraction = vm.duration > 0 ? clamp(live / vm.duration) : 0
            let frac = dragging ? dragFraction : currentFraction
            let displayElapsed = dragging ? dragFraction * vm.duration : live

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                            .frame(height: dragging ? 6 : 4)
                        Capsule()
                            .fill(LinearGradient(colors: fillColors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * frac, height: dragging ? 6 : 4)
                    }
                    .frame(height: 16, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                dragging = true
                                dragFraction = clamp(v.location.x / geo.size.width)
                            }
                            .onEnded { v in
                                vm.seek(toFraction: clamp(v.location.x / geo.size.width))
                                dragging = false
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(Text("\(Int(frac * 100)) percent"))
                }
                .frame(height: 16)

                HStack {
                    Text(timeString(displayElapsed))
                    Spacer()
                    Text(timeString(vm.duration))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var fillColors: [Color] {
        vm.palette.count >= 2 ? Array(vm.palette.prefix(2)) : [.white.opacity(0.9), .white.opacity(0.7)]
    }
    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

// MARK: - File shelf

struct ShelfStrip: View {
    @ObservedObject var vm: NowPlayingModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.shelfFiles, id: \.self) { url in
                        FileChip(url: url) { vm.removeFile(url) }
                    }
                }
            }
            Button {
                withAnimation { vm.clearShelf() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Clear shelf")
        }
        .frame(height: 40)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}

struct FileChip: View {
    let url: URL
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: 90)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.10))
        )
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove", role: .destructive) { onRemove() }
        }
    }
}

private struct ControlButton: View {
    var system: String
    var size: CGFloat
    var label: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size + 14, height: size + 14)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

private func timeString(_ t: Double) -> String {
    guard t.isFinite, t > 0 else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Snapshot (offscreen render for verification, no screen-recording needed)

@MainActor
enum NotchSnapshotter {
    static func sampleModel(withShelf: Bool = false) -> NowPlayingModel {
        let model = NowPlayingModel()
        model.title = "Midnight City"
        model.artist = "M83"
        model.album = "Hurry Up, We're Dreaming"
        model.duration = 244
        model.isPlaying = true
        // Seed the elapsed/timestamp anchor so liveElapsed() (and the scrubber)
        // report ~78s. (No backend is running in snapshot mode, so seek is a no-op
        // beyond setting the anchor.)
        model.seek(toTime: 78)
        model.hasContent = true
        model.palette = [
            Color(red: 0.95, green: 0.55, blue: 0.25),
            Color(red: 0.85, green: 0.25, blue: 0.45),
            Color(red: 0.40, green: 0.20, blue: 0.55)
        ]
        // Neutral placeholder lines (not real lyrics) for layout verification.
        model.lyrics = [
            LyricLine(time: 60, text: "\u{266A} previous line placeholder"),
            LyricLine(time: 70, text: "earlier verse placeholder"),
            LyricLine(time: 78, text: "current synced line placeholder"),
            LyricLine(time: 86, text: "upcoming line placeholder"),
            LyricLine(time: 94, text: "later line placeholder")
        ]
        model.currentLyricIndex = 2
        if withShelf {
            model.shelfFiles = [
                URL(fileURLWithPath: "/tmp/Quarterly Report.pdf"),
                URL(fileURLWithPath: "/tmp/screenshot.png")
            ]
        }
        return model
    }

    /// Overlays a panel on the solid-black notch shape at a fixed width and its
    /// natural (content-driven) height — matching the live app's morphing island.
    static func island<P: View>(_ panel: P, width: CGFloat) -> some View {
        panel
            .frame(width: width)
            .background(NotchShape().fill(.black))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func run(to directory: String) {
        let metrics = NotchMetrics(notchWidth: 200, notchHeight: 34)

        // Expanded island at each size (content scales; height follows content).
        for size in NotchSize.allCases {
            let width = max(metrics.notchWidth + size.extraWidth, size.minWidth)
            let panel = ExpandedPanel(vm: sampleModel(), scale: size.contentScale)
            write(island(panel, width: width), to: "\(directory)/canopy_expanded_\(size.rawValue).png")
        }
        // Default expanded image = medium.
        let mediumWidth = max(metrics.notchWidth + NotchSize.medium.extraWidth, NotchSize.medium.minWidth)
        write(island(ExpandedPanel(vm: sampleModel(), scale: 1), width: mediumWidth),
              to: "\(directory)/canopy_expanded.png")

        let collapsed = ZStack {
            NotchShape().fill(.black)
            CollapsedPill(vm: sampleModel(), metrics: metrics)
        }
        .frame(width: metrics.notchWidth + 172, height: metrics.notchHeight)

        // Expanded with the file shelf populated.
        let shelf = island(ExpandedPanel(vm: sampleModel(withShelf: true), scale: 1), width: mediumWidth)

        let banner = ZStack {
            NotchShape().fill(.black)
            BannerView(banner: NotchBanner(
                title: "Messages",
                subtitle: "Alex",
                body: "See you at 8 \u{1F44B}",
                icon: nil,
                kind: .system
            ))
        }
        .frame(width: 440, height: 80)

        write(collapsed, to: "\(directory)/canopy_collapsed.png")
        write(shelf, to: "\(directory)/canopy_shelf.png")
        write(banner, to: "\(directory)/canopy_banner.png")

        // Liquid Glass widget presets.
        for preset in WidgetPreset.allCases {
            let widgetModel = sampleModel()
            let widget = WidgetView(vm: widgetModel, preset: preset, snapshotMode: true)
                .frame(width: preset.size.width, height: preset.size.height)
            write(widget, to: "\(directory)/canopy_widget_\(preset.rawValue).png")
        }
    }

    static func write<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = false
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed: \(path)\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
    }
}
