import SwiftUI
import UniformTypeIdentifiers

/// The root view that fills the floating notch window. Hover (or an active file
/// drop) swaps between the collapsed pill and the expanded media panel.
struct NotchView: View {
    @ObservedObject var vm: NowPlayingModel
    let metrics: NotchMetrics
    let onPresent: (NotchPresentation) -> Void

    @State private var hovering = false

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
                ExpandedPanel(vm: vm)
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
                NotchShape().fill(.black)
                if isOpen {
                    NotchShape()
                        .fill(
                            LinearGradient(
                                colors: vm.palette.prefix(2).map { $0.opacity(0.22) },
                                startPoint: .topLeading, endPoint: .bottomTrailing
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
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: presentation)
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

    private var accent: Color { vm.palette.first ?? .white }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: vm.artwork, size: 52, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.hasMedia ? vm.title : "Nothing Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(vm.hasMedia ? vm.artist : "Canopy")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerBars(active: vm.isPlaying, color: .white.opacity(0.85))
            }

            if let lyric = vm.currentLyric {
                Text(lyric)
                    .font(.system(size: 12, weight: .semibold))
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

            HStack(spacing: 28) {
                ControlButton(system: "backward.fill", size: 16) { vm.previous() }
                ControlButton(system: vm.isPlaying ? "pause.fill" : "play.fill", size: 22) { vm.togglePlayPause() }
                ControlButton(system: "forward.fill", size: 16) { vm.next() }
            }
            .disabled(!vm.hasMedia)
            .opacity(vm.hasMedia ? 1 : 0.4)

            if !vm.shelfFiles.isEmpty {
                ShelfStrip(vm: vm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        VStack(spacing: 4) {
            GeometryReader { geo in
                let frac = dragging ? dragFraction : currentFraction
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

    private var fillColors: [Color] {
        vm.palette.count >= 2 ? Array(vm.palette.prefix(2)) : [.white.opacity(0.9), .white.opacity(0.7)]
    }
    private var currentFraction: Double {
        vm.duration > 0 ? clamp(vm.elapsed / vm.duration) : 0
    }
    private var displayElapsed: Double {
        dragging ? dragFraction * vm.duration : vm.elapsed
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
        model.elapsed = 78
        model.isPlaying = true
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

    static func run(to directory: String) {
        let model = sampleModel()
        let metrics = NotchMetrics(notchWidth: 200, notchHeight: 34)

        let expanded = ZStack {
            NotchShape().fill(.black)
            NotchShape().fill(LinearGradient(colors: model.palette.prefix(2).map { $0.opacity(0.22) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            ExpandedPanel(vm: model)
        }
        .frame(width: 460, height: 210)

        let collapsed = ZStack {
            NotchShape().fill(.black)
            CollapsedPill(vm: model, metrics: metrics)
        }
        .frame(width: metrics.notchWidth + 172, height: metrics.notchHeight)

        // A separate instance with the file shelf populated.
        let shelfModel = sampleModel(withShelf: true)
        let shelf = ZStack {
            NotchShape().fill(.black)
            NotchShape().fill(LinearGradient(colors: model.palette.prefix(2).map { $0.opacity(0.22) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            ExpandedPanel(vm: shelfModel)
        }
        .frame(width: 460, height: 268)

        let banner = ZStack {
            NotchShape().fill(.black)
            NotchShape().fill(LinearGradient(colors: model.palette.prefix(2).map { $0.opacity(0.22) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            BannerView(banner: NotchBanner(
                title: "Messages",
                subtitle: "Alex",
                body: "See you at 8 \u{1F44B}",
                icon: nil,
                kind: .system
            ))
        }
        .frame(width: 440, height: 80)

        write(expanded, to: "\(directory)/canopy_expanded.png")
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
