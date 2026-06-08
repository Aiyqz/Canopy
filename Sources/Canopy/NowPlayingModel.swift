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

    /// Human-readable name of the active media backend (for the menu).
    @Published var backendName: String = "starting…"

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

    private let controller = MediaController()
    private var ticker: Timer?
    // Elapsed playback is reconstructed from the backend's elapsed + timestamp
    // pair so the scrubber stays accurate without continuous polling.
    private var elapsedBase: Double = 0
    private var elapsedTimestamp: Date = Date()
    private var artworkHash: Int = 0
    private var trackKey: String = ""
    private var bannerQueue: [NotchBanner] = []
    private var bannerDismiss: DispatchWorkItem?

    var hasMedia: Bool { !title.isEmpty }
    var shelfPinned: Bool { !shelfFiles.isEmpty || isDropTargeted }
    var bannerActive: Bool { currentBanner != nil }
    var mediaAvailable: Bool { controller.isAvailable }

    var currentLyric: String? {
        guard let i = currentLyricIndex, lyrics.indices.contains(i) else { return nil }
        let text = lyrics[i].text
        return text.isEmpty ? nil : text
    }

    func start() {
        controller.onBackendResolved = { [weak self] backend in
            self?.backendName = backend.rawValue
        }
        controller.onSnapshot = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        controller.start()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Tear down timers and the media backend (called on app termination).
    func stop() {
        ticker?.invalidate()
        ticker = nil
        controller.stop()
        AudioLevelMonitor.shared.setEnabled(false)
    }

    private func tick() {
        // While paused the projection is constant, so there's nothing to advance —
        // and reassigning `elapsed` would needlessly churn every observer (the
        // notch + widget) twice a second. The scrubber/clock animate via their own
        // TimelineViews, so this tick only exists to advance lyrics during playback.
        guard isPlaying else { return }
        let live = liveElapsed()
        if abs(live - elapsed) > 0.01 { elapsed = live }
        updateLyricIndex()
    }

    /// Elapsed playback time projected to `date` from the last sampled
    /// (elapsedTime, timestamp) anchor — the backend reports elapsed *as of* its
    /// timestamp, so while playing we extrapolate forward from there. This is
    /// what drives the scrubber smoothly without continuous polling.
    func liveElapsed(at date: Date = Date()) -> Double {
        guard duration > 0 else { return max(elapsedBase, 0) }
        let projected = isPlaying
            ? elapsedBase + date.timeIntervalSince(elapsedTimestamp)
            : elapsedBase
        return min(max(projected, 0), duration)
    }

    private func apply(_ snap: NowPlayingSnapshot) {
        // Identify the track up front: backends often push the new title/artist
        // in one update and the (larger) artwork in a following one.
        let key = "\(snap.title)|\(snap.artist)|\(snap.album)"
        let trackChanged = key != trackKey && !snap.title.isEmpty
        let wasFirst = trackKey.isEmpty

        title = snap.title
        artist = snap.artist
        album = snap.album
        duration = snap.duration
        isPlaying = snap.isPlaying

        // Anchor the scrubber to this measurement and project it to "now".
        elapsedBase = snap.elapsed
        elapsedTimestamp = snap.timestamp
        if isPlaying, duration > 0 {
            elapsed = min(max(snap.elapsed + Date().timeIntervalSince(snap.timestamp), 0), duration)
        } else {
            elapsed = snap.elapsed
        }

        // On a real track change, drop the previous track's artwork immediately so
        // a new song never displays the old album. If this same update also carries
        // the new art, the block below sets it in the same render pass (no flash);
        // otherwise we show the placeholder until the new art arrives.
        if trackChanged {
            artwork = nil
            artworkHash = 0
            palette = ColorExtractor.fallback
        }

        // Only react to artwork when this update actually carried it; a partial
        // diff that omits art must not wipe the current image (within a track).
        if snap.carriedArtwork {
            if let data = snap.artworkData {
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
                // Nothing playing → reset to the default gradient.
                artwork = nil
                artworkHash = 0
                palette = ColorExtractor.fallback
            }
        }

        if !title.isEmpty { hasContent = true }

        // Capture system audio for the EQ bars only while actually playing.
        AudioLevelMonitor.shared.setEnabled(isPlaying && !title.isEmpty)

        // New track? refresh lyrics + schedule a now-playing banner.
        if trackChanged {
            trackKey = key
            loadLyrics(title: title, artist: artist, album: album, duration: duration, key: key)
            if isPlaying && !wasFirst {
                scheduleNowPlayingBanner(forKey: key)
            }
        }
        updateLyricIndex()
    }

    /// Fire the now-playing banner shortly after a track change so the new
    /// artwork (which usually lands a beat after the metadata) is included rather
    /// than the previous track's.
    private func scheduleNowPlayingBanner(forKey key: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.trackKey == key, self.isPlaying, !self.title.isEmpty else { return }
            self.pushBanner(NotchBanner(
                title: self.title,
                subtitle: self.artist,
                body: nil,
                icon: self.artwork,
                kind: .nowPlaying
            ))
        }
    }

    // MARK: Banners

    func pushBanner(_ banner: NotchBanner) {
        bannerQueue.append(banner)
        // A notification burst shouldn't queue minutes of banners — keep the
        // newest few and drop the backlog.
        if bannerQueue.count > 6 {
            bannerQueue.removeFirst(bannerQueue.count - 6)
        }
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
        controller.send(.togglePlayPause)
        // Optimistic; a fresh snapshot will confirm. Re-anchor elapsed so the
        // scrubber keeps moving (or freezes) correctly until then.
        isPlaying.toggle()
        elapsedBase = elapsed
        elapsedTimestamp = Date()
    }

    func next() {
        controller.send(.nextTrack)
    }

    func previous() {
        controller.send(.previousTrack)
    }

    func seek(toFraction fraction: Double) {
        seek(toTime: max(0, min(fraction, 1)) * duration)
    }

    func seek(toTime time: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(time, duration))
        elapsed = t
        elapsedBase = t
        elapsedTimestamp = Date()
        controller.seek(toTime: t)
        updateLyricIndex()
    }

    // MARK: File shelf

    /// Appends dropped files to the shelf. Skips duplicates and anything that
    /// isn't a real on-disk file. Mutating the published `shelfFiles` flips
    /// `shelfPinned`, which expands the notch to reveal the shelf.
    func addFiles(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            let standardized = url.standardizedFileURL
            guard fm.fileExists(atPath: standardized.path),
                  !shelfFiles.contains(standardized) else { continue }
            shelfFiles.append(standardized)
        }
    }

    func removeFile(_ url: URL) {
        shelfFiles.removeAll { $0 == url }
    }

    func clearShelf() {
        shelfFiles.removeAll()
    }
}
