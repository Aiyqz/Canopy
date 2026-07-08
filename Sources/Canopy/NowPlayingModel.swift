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
    private var pollTimer: Timer?
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

    /// 当前行内的播放进度 0..1，用于歌词“逐字渐变”高亮（卡拉OK 效果）。
    /// 注意：LRCLIB 只提供行级时间戳，所以这是“整行内的进度填充”，并非逐字精确。
    var currentLyricProgress: Double {
        guard let i = currentLyricIndex, lyrics.indices.contains(i) else { return 0 }
        let start = lyrics[i].time
        let end = lyrics.indices.contains(i + 1) ? lyrics[i + 1].time : (duration > start ? duration : start + 5)
        let span = max(end - start, 0.5)
        return min(max((elapsed - start) / span, 0), 1)
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

        // 周期性轮询：MediaRemote 只在“切歌/播放状态变化”时发通知，
        // 若应用启动前就在播放、且之后没有切歌，初始 getNowPlayingInfo
        // 可能返回空，导致永远收不到歌词。这里每 3s 主动拉一次做兜底。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
            let hasMedia = (info[MediaRemote.kTitle] as? String)?.isEmpty == false
            if hasMedia {
                Task { @MainActor in self?.apply(info) }
                return
            }
            // MediaRemote 取不到（macOS 26 私有 API 在开发者预览下失效）→
            // 用 AppleScript 直接问 Spotify / Music 当前播放，作为兜底。
            Task.detached {
                if let scriptInfo = fetchNowPlayingViaScript() {
                    Task { @MainActor in self?.apply(scriptInfo) }
                }
                // 两边都取不到：保留上一次状态，避免轮询偶发失败把歌词清空 / elapsed 归零
            }
        }
    }

    private func refreshPlaying() {
        MediaRemote.shared.getIsPlaying { [weak self] playing in
            Task { @MainActor in
                if playing {
                    self?.isPlaying = true
                } else if fetchNowPlayingViaScript() != nil {
                    // 兜底：AppleScript 能取到说明正在播放
                    self?.isPlaying = true
                } else {
                    self?.isPlaying = false
                }
            }
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

// MARK: - AppleScript 兜底（MediaRemote 在 macOS 26 下取不到时）

private let scriptBridgePath = "/tmp/canopy_np.scpt"
private let scriptLock = NSLock()
private var cachedScriptInfo: [String: Any]?
private var cachedScriptTime: Date = .distantPast

private func ensureScriptBridge() {
    let script = """
    if application "Spotify" is running then
      tell application "Spotify"
        if player state is playing then
          return "SPOTIFY|" & (name of current track) & "|" & (artist of current track) & "|" & (album of current track) & "|" & (duration of current track as text) & "|" & (player position as text)
        end if
      end tell
    end if
    if application "Music" is running then
      tell application "Music"
        if player state is playing then
          return "MUSIC|" & (name of current track) & "|" & (artist of current track) & "|" & (album of current track) & "|" & (duration of current track as text) & "|" & (player position as text)
        end if
      end tell
    end if
    return "NONE"
    """
    try? script.write(to: URL(fileURLWithPath: scriptBridgePath), atomically: true, encoding: .utf8)
}

/// 用 AppleScript 直接读取 Spotify / Music 的当前播放，
/// 返回与 MediaRemote 同形状的字典（kTitle/kArtist/...），取不到返回 nil。
/// 带缓存 + 串行锁：避免并发 osascript 相互干扰导致偶发返回 nil。
func fetchNowPlayingViaScript() -> [String: Any]? {
    scriptLock.lock()
    defer { scriptLock.unlock() }
    ensureScriptBridge()
    guard FileManager.default.fileExists(atPath: scriptBridgePath) else { return cachedIfFresh() }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = [scriptBridgePath]
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do { try proc.run() } catch { return cachedIfFresh() }
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty, raw != "NONE" else { return cachedIfFresh() }
    let parts = raw.components(separatedBy: "|")
    guard parts.count >= 6, parts[0] == "SPOTIFY" || parts[0] == "MUSIC" else { return cachedIfFresh() }
    let title = parts[1], artist = parts[2], album = parts[3]
    guard !title.isEmpty, !artist.isEmpty else { return cachedIfFresh() }
    var duration = Double(parts[4]) ?? 0
    let position = Double(parts[5]) ?? 0
    if parts[0] == "SPOTIFY", duration > 10000 { duration /= 1000 } // Spotify 返回毫秒
    let info: [String: Any] = [
        MediaRemote.kTitle: title,
        MediaRemote.kArtist: artist,
        MediaRemote.kAlbum: album,
        MediaRemote.kDuration: duration,
        MediaRemote.kElapsed: position,
        MediaRemote.kPlaybackRate: 1.0
    ]
    cachedScriptInfo = info
    cachedScriptTime = Date()
    return info
}

/// 真正的拉取偶发失败时，5s 内复用上一次成功结果，避免把歌词清空。
private func cachedIfFresh() -> [String: Any]? {
    if let c = cachedScriptInfo, Date().timeIntervalSince(cachedScriptTime) < 5 {
        return c
    }
    return nil
}
