import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Observable now-playing state, fed by MediaRemote notifications + polling.
/// Also owns lyrics, the extracted color palette, and the file-drop shelf.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var artwork: NSImage?
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 0
    @Published var elapsed: Double = 0

    /// True once we've seen any track at all.
    @Published var hasContent: Bool = false

    // Apple-Music-style gradient palette derived from album art.
    @Published var palette: [Color] = ColorExtractor.fallback

    // Time-synced lyrics.
    @Published var lyrics: [LyricLine] = []
    @Published var currentLyricIndex: Int?

    // File-drop shelf.
    @Published var shelfFiles: [URL] = []
    @Published var isDropTargeted: Bool = false

    // Notch banners (now-playing changes + mirrored notifications).
    @Published var currentBanner: NotchBanner?

    private var ticker: Timer?
    private var lastTick = Date()
    private var artworkHash: Int = 0
    private var trackKey: String = ""
    private var bannerQueue: [NotchBanner] = []
    private var bannerDismiss: DispatchWorkItem?

    var hasMedia: Bool { !title.isEmpty }
    var shelfPinned: Bool { !shelfFiles.isEmpty || isDropTargeted }
    var bannerActive: Bool { currentBanner != nil }

    var currentLyric: String? {
        guard let i = currentLyricIndex, lyrics.indices.contains(i) else { return nil }
        let text = lyrics[i].text
        return text.isEmpty ? nil : text
    }

    func start() {
        MediaRemote.shared.registerForNotifications()

        let nc = NotificationCenter.default
        nc.addObserver(forName: MediaRemote.infoDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        nc.addObserver(forName: MediaRemote.isPlayingDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPlaying() }
        }

        refresh()
        refreshPlaying()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if isPlaying, duration > 0 {
            elapsed = min(elapsed + dt, duration)
        }
        updateLyricIndex()
    }

    func refresh() {
        MediaRemote.shared.getNowPlayingInfo { [weak self] info in
            Task { @MainActor in self?.apply(info) }
        }
    }

    private func refreshPlaying() {
        MediaRemote.shared.getIsPlaying { [weak self] playing in
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    private func apply(_ info: [String: Any]) {
        title = info[MediaRemote.kTitle] as? String ?? ""
        artist = info[MediaRemote.kArtist] as? String ?? ""
        album = info[MediaRemote.kAlbum] as? String ?? ""
        duration = info[MediaRemote.kDuration] as? Double ?? 0
        elapsed = info[MediaRemote.kElapsed] as? Double ?? 0
        lastTick = Date()

        if let rate = info[MediaRemote.kPlaybackRate] as? Double {
            isPlaying = rate > 0
        }

        if let data = info[MediaRemote.kArtworkData] as? Data {
            let h = data.hashValue
            if h != artworkHash {
                artworkHash = h
                let image = NSImage(data: data)
                artwork = image
                withAnimation(.easeInOut(duration: 0.6)) {
                    palette = ColorExtractor.palette(from: image)
                }
            }
        } else if title.isEmpty {
            artwork = nil
            artworkHash = 0
            palette = ColorExtractor.fallback
        }

        if !title.isEmpty { hasContent = true }

        // New track? refresh lyrics + show a now-playing banner.
        let key = "\(title)|\(artist)|\(album)"
        if key != trackKey, !title.isEmpty {
            let wasFirst = trackKey.isEmpty
            trackKey = key
            loadLyrics(title: title, artist: artist, album: album, duration: duration, key: key)
            if isPlaying && !wasFirst {
                pushBanner(NotchBanner(
                    title: title,
                    subtitle: artist,
                    body: nil,
                    icon: artwork,
                    kind: .nowPlaying
                ))
            }
        }
        updateLyricIndex()
    }

    // MARK: Banners

    func pushBanner(_ banner: NotchBanner) {
        bannerQueue.append(banner)
        if currentBanner == nil { showNextBanner() }
    }

    private func showNextBanner() {
        bannerDismiss?.cancel()
        guard !bannerQueue.isEmpty else {
            withAnimation(.easeOut(duration: 0.25)) { currentBanner = nil }
            return
        }
        let next = bannerQueue.removeFirst()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { currentBanner = next }
        let work = DispatchWorkItem { [weak self] in self?.advanceBanner() }
        bannerDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func advanceBanner() {
        if bannerQueue.isEmpty {
            withAnimation(.easeOut(duration: 0.25)) { currentBanner = nil }
        } else {
            showNextBanner()
        }
    }

    func dismissBanner() {
        bannerQueue.removeAll()
        bannerDismiss?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { currentBanner = nil }
    }

    // MARK: Lyrics

    private func loadLyrics(title: String, artist: String, album: String, duration: Double, key: String) {
        lyrics = []
        currentLyricIndex = nil
        Task { [weak self] in
            let lines = await LyricsService.fetchSynced(
                title: title, artist: artist, album: album, duration: duration
            )
            await MainActor.run {
                guard let self, self.trackKey == key else { return }
                self.lyrics = lines
                self.updateLyricIndex()
            }
        }
    }

    private func updateLyricIndex() {
        guard !lyrics.isEmpty else {
            if currentLyricIndex != nil { currentLyricIndex = nil }
            return
        }
        var idx: Int?
        for (i, line) in lyrics.enumerated() {
            if line.time <= elapsed + 0.25 { idx = i } else { break }
        }
        if idx != currentLyricIndex {
            withAnimation(.easeInOut(duration: 0.3)) { currentLyricIndex = idx }
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        MediaRemote.shared.send(.togglePlayPause)
        isPlaying.toggle() // optimistic; corrected by notification
        scheduleRefresh()
    }

    func next() {
        MediaRemote.shared.send(.nextTrack)
        scheduleRefresh()
    }

    func previous() {
        MediaRemote.shared.send(.previousTrack)
        scheduleRefresh()
    }

    func seek(toFraction fraction: Double) {
        seek(toTime: max(0, min(fraction, 1)) * duration)
    }

    func seek(toTime time: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(time, duration))
        elapsed = t
        lastTick = Date()
        MediaRemote.shared.setElapsed(t)
        updateLyricIndex()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
            self?.refreshPlaying()
        }
    }

    // MARK: File shelf

    func addFiles(_ urls: [URL]) {
        for url in urls where !shelfFiles.contains(url) {
            shelfFiles.append(url)
        }
    }

    func removeFile(_ url: URL) {
        shelfFiles.removeAll { $0 == url }
    }

    func clearShelf() {
        shelfFiles.removeAll()
    }
}
