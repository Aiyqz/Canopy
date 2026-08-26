import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 当前播放状态（可被 UI 观察）。数据来源：MediaRemote 通知 + 主动轮询。
/// 同时管理歌词、从专辑封面提取的渐变色板、以及文件拖放暂存区。
@MainActor
@Observable
final class NowPlayingModel {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: NSImage?
    var isPlaying: Bool = false
    var duration: Double = 0
    var elapsed: Double = 0

    /// 只要曾经出现过任意曲目就为 true（用于判断是否有可显示内容）。
    var hasContent: Bool = false

    // 从专辑封面提取的渐变色板（类似 Apple Music 的风格）。
    var palette: [Color] = ColorExtractor.fallback

    // 时间同步歌词（按时间戳排序的行）。
    var lyrics: [LyricLine] = []
    var currentLyricIndex: Int?

    // 文件拖放暂存区（把文件拖到灵动岛可暂存）。
    var shelfFiles: [URL] = []
    var isDropTargeted: Bool = false

    // 灵动岛横幅（切歌 / 系统通知镜像时弹出）。
    var currentBanner: NotchBanner?

    private var pollTimer: Timer?
    private var frameTimer: Timer?
    /// 死推算基准：最近一次 refresh/AppleScript 回传的真实播放位置(秒) 及其时刻。
    /// 每帧用 基准位置 + (当前墙钟 - 基准时刻) 连续推算播放头，避免 0.5s 定格 + 3s 硬重置跳变。
    private var basePosition: Double = 0
    private var baseTime = Date()
    private var wasPlaying = false
    private var artworkHash: Int = 0
    private var trackKey: String = ""
    private var bannerQueue: [NotchBanner] = []
    private var bannerDismiss: DispatchWorkItem?

    // 同步模式状态机：优先 MediaRemote 通知/轮询；其持续取不到时降级到 AppleScript 兜底，
    // 避免在无谓场景每 3s 起一个 osascript 进程烧 CPU/电池。
    private enum SyncMode { case mediaRemote, appleScript }
    private var syncMode: SyncMode = .mediaRemote
    private var mrEmptyStreak = 0

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
        progress(for: currentLyricIndex, elapsed: elapsed)
    }

    /// 与死推算同公式、但**不读** `@Published elapsed` 的播放头估算（读 basePosition + 墙钟）。
    /// 供 TimelineView 叶子在自身节奏里驱动卡拉OK渐变，从而解除对「每帧发布 elapsed」的依赖，
    /// 配合 @Observable 细粒度追踪，把高频重绘收敛到渐变层本身。
    func liveElapsed() -> Double {
        duration > 0 ? min(basePosition + Date().timeIntervalSince(baseTime), duration) : elapsed
    }

    /// 给定某行索引与播放头，算该行内 0..1 进度（与 currentLyricProgress 同逻辑，但用传入 elapsed）。
    func progress(for index: Int?, elapsed e: Double) -> Double {
        LyricsIndex.progress(for: index, elapsed: e, lyrics: lyrics, duration: duration)
    }

    /// 启动：注册 MediaRemote 通知、首次刷新、并启动 3s 兜底轮询。
    func start() {
        canopyLog("[Canopy] start() 被调用")
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

        // MediaRemote 在 macOS 26 对 Spotify 拿不到 nowPlayingInfo（title 恒空），
        // 只能靠 AppleScript 兜底。若启动时同步探测即命中，立即应用并切到 appleScript 模式，
        // 避免「连续 2 次空轮询（各 15s）」才降级、用户启动后干等 30s 没歌词。
        if let scriptInfo = fetchNowPlayingViaScript() {
            canopyLog("[Canopy] start: 启动即 AppleScript 命中，立即应用")
            syncMode = .appleScript
            apply(scriptInfo)
        }

        reconfigurePoll()
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        // 15fps 足够驱动卡拉OK渐变（填充行跨度数秒，逐帧位移≈2% < 4% 过渡带，肉眼无差别），
        // 相比 30fps 再省约一半 SwiftUI 重绘开销；结合 @Observable 按属性追踪，重绘爆炸半径已收缩到进度条/渐变层。
        let timer = Timer.scheduledTimer(withTimeInterval: 1/15, repeats: true) { [weak self] _ in
            // 定时器本就在主线程/主 RunLoop 触发，用 assumeIsolated 同步调用，零异步跳转开销。
            MainActor.assumeIsolated { self?.frameTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// 按当前同步模式重建轮询定时器：MR 可用时仅 15s 慢速安全兜底（几乎不耗电）；
    /// 降级到 AppleScript 兜底时 3s 保响应。重复调用会先失效旧定时器，天然防重复 start 泄漏。
    private func reconfigurePoll() {
        pollTimer?.invalidate()
        pollTimer = nil
        let interval: TimeInterval = syncMode == .appleScript ? 3 : 15
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// 每帧调用：在 isPlaying 时基于墙钟时间连续推算播放头位置。
    private func frameTick() {
        guard isPlaying else {
            wasPlaying = false
            stopFrameTimer() // 暂停/空闲：停表，不再空转烧 CPU
            return
        }
        let now = Date()
        if !wasPlaying {
            // 恢复播放：以当前 elapsed 为基准重新计时，避免从旧基准一下子跳出来
            basePosition = elapsed
            baseTime = now
        }
        if duration > 0 {
            elapsed = min(basePosition + now.timeIntervalSince(baseTime), duration)
        }
        wasPlaying = true
        updateLyricIndex()
    }

    /// 拉取当前播放信息：优先 MediaRemote；其持续取不到时经 SyncMode 状态机降级到 AppleScript 兜底。
    func refresh() {
        MediaRemote.shared.getNowPlayingInfo { [weak self] info in
            let hasMedia = (info[MediaRemote.kTitle] as? String)?.isEmpty == false
            if hasMedia {
                canopyLog("[Canopy] refresh: MediaRemote 取到播放信息")
                Task { @MainActor in
                    guard let self else { return }
                    // MR 恢复可用：切回 mediaRemote 模式并放慢轮询（省电），清零失效计数。
                    if self.syncMode != .mediaRemote {
                        self.syncMode = .mediaRemote
                        self.reconfigurePoll()
                    }
                    self.mrEmptyStreak = 0
                    self.apply(info)
                }
                return
            }
            // MediaRemote 取不到：先给 MR 两次机会（避免切歌间隙误判），确认持续失效再降级 AppleScript 兜底。
            Task { @MainActor in
                guard let self else { return }
                if self.syncMode == .appleScript {
                    // 已在兜底模式：仅此路径才起 osascript 进程。
                    if let scriptInfo = fetchNowPlayingViaScript() {
                        canopyLog("[Canopy] refresh: AppleScript 兜底取到 \(scriptInfo[MediaRemote.kTitle] ?? "")")
                        self.apply(scriptInfo)
                    } else {
                        canopyLog("[Canopy] refresh: MediaRemote 空 + AppleScript 也空")
                    }
                    return
                }
                self.mrEmptyStreak += 1
                if self.mrEmptyStreak >= 1 {
                    self.syncMode = .appleScript
                    self.reconfigurePoll()
                }
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
                    self?.stopFrameTimer() // 暂停/停止：显式停表，避免依赖下一帧隐式自停的时序缝隙
                }
                if self?.isPlaying == true { self?.startFrameTimer() }
            }
        }
    }

    /// 把一份播放信息字典写入模型各字段（标题/艺人/时长/位置/色板/歌词），并触发切歌横幅。
    private func apply(_ info: [String: Any]) {
        title = info[MediaRemote.kTitle] as? String ?? ""
        artist = info[MediaRemote.kArtist] as? String ?? ""
        album = info[MediaRemote.kAlbum] as? String ?? ""
        duration = info[MediaRemote.kDuration] as? Double ?? 0
        canopyLog("[Canopy] apply 检测到: title=\(title) artist=\(artist) duration=\(duration)")
        let pos = info[MediaRemote.kElapsed] as? Double ?? 0
        // 死推算基准校正：用真实回传位置重置基准，播放头由 frameTick 连续推算。
        // 仅在「切歌」或「推算漂移超过 0.5s」时才硬重置 elapsed，避免每 3s 轮询把进度条/卡拉OK向后微跳。
        let incomingKey = "\(title)|\(artist)|\(album)"
        if incomingKey != trackKey || abs(elapsed - pos) > 0.5 {
            basePosition = pos
            baseTime = Date()
            elapsed = pos
        } else {
            // 小漂移：仅轻量校正基准，不回写 elapsed，保持推算平滑
            basePosition = pos
            baseTime = Date()
        }

        if let rate = info[MediaRemote.kPlaybackRate] as? Double {
            isPlaying = rate > 0
        }
        if isPlaying { startFrameTimer() } // 开始播放：启动 60fps 高帧率链路

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

        // 是否切歌？是则重新拉歌词，并弹出“正在播放”横幅。
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

    /// 异步拉取并加载时间同步歌词（按 trackKey 防止陈旧结果覆盖新歌）。
    private func loadLyrics(title: String, artist: String, album: String, duration: Double, key: String) {
        lyrics = []
        currentLyricIndex = nil
        canopyLog("[Canopy] loadLyrics 开始: \(title) - \(artist)")
        Task { [weak self] in
            let lines = await LyricsService.fetchSynced(
                title: title, artist: artist, album: album, duration: duration
            )
            await MainActor.run {
                guard let self, self.trackKey == key else { return }
                self.lyrics = lines
                self.updateLyricIndex()
                canopyLog("[Canopy] loadLyrics 完成: 拉到 \(lines.count) 行")
            }
        }
    }

    private func updateLyricIndex() {
        // 索引核心逻辑已抽到 UI 无关的纯函数 LyricsIndex.compute（含循环重播 / 进度条回拖的
        // 下界修复），此处仅把模型状态喂进去、且仅在结果变化时带动画写回，避免每帧无谓重绘。
        let next = LyricsIndex.compute(lyrics: lyrics, elapsed: elapsed, currentIndex: currentLyricIndex)
        if next != currentLyricIndex {
            canopyLog("[Canopy] updateLyricIndex: \(currentLyricIndex ?? -1) → \(next ?? -1) (elapsed=\(String(format: "%.2f", elapsed)) 歌词数=\(lyrics.count) 首行时间=\(String(format: "%.2f", lyrics.first?.time ?? 0)))")
            withAnimation(.easeInOut(duration: 0.3)) { currentLyricIndex = next }
        }
    }

    // MARK: Commands

    /// 播放/暂停切换：发送指令并乐观更新 isPlaying，同时驱动高帧率定时器启停。
    func togglePlayPause() {
        MediaRemote.shared.send(.togglePlayPause)
        isPlaying.toggle() // 乐观更新：先立即切换，随后由通知/轮询纠偏
        if isPlaying { startFrameTimer() } else { stopFrameTimer() }
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

    /// 跳转到指定播放位置（秒）：同步重置死推算基准，避免渐变跳变。
    func seek(toTime time: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(time, duration))
        elapsed = t
        basePosition = t
        baseTime = Date()
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
