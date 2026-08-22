import Foundation

/// 纯函数歌词索引 / 进度计算（与 UI、@MainActor、AppKit 完全无关）。
///
/// 抽出这一层有两个目的：
/// 1. 让 `NowPlayingModel.updateLyricIndex()` 直接复用，避免「逐帧推算的播放头」与
///    「歌词索引」两套逻辑各写一份、悄悄分叉；
/// 2. 让回归测试能脱离 SwiftUI / 主线程，直接对最关键的「循环重播 / 进度条回拖」索引卡死
///    bug 做单测锁定（见 Tests/CanopyTests/LyricsIndexTests.swift）。
public enum LyricsIndex {

    /// 给定歌词行、播放头(秒)、当前高亮索引，返回「应当高亮的歌词行索引」。
    ///
    /// **关键修复（原 bug 根因）**：同一首歌循环重播、或进度条往回拖时，`elapsed` 会回退到
    /// 当前行之前。旧实现只校验上界（`elapsed + 0.25 < 下一行时间`），误判「仍在本行」→
    /// 索引卡死、歌词停更，只能重新播放才恢复。现在快速路径必须**同时校验下界**
    /// （当前行起始时间）：播放头已落到本行之前时，立即失效快速路径、走全量扫描，索引才会回退。
    ///
    /// - Parameters:
    ///   - lyrics: 按时间升序排列的歌词行（空数组返回 `nil`）。
    ///   - elapsed: 当前播放头（秒）。
    ///   - currentIndex: 上一帧的高亮索引（用于快速路径，可传 `nil`）。
    /// - Returns: 应高亮行索引；无歌词返回 `nil`。
    public static func compute(lyrics: [LyricLine], elapsed: Double, currentIndex: Int?) -> Int? {
        guard !lyrics.isEmpty else { return nil }

        // 快速路径：仅当播放头仍落在当前行区间 [start, nextTime) 内才跳过全量扫描，
        // 避免每帧都遍历全部歌词（15fps 下省掉 99% 的扫描）。
        // 必须同时校验下界（当前行起始时间）——这是修复回拖/循环卡死的核心。
        if let i = currentIndex, lyrics.indices.contains(i) {
            let start = lyrics[i].time
            let nextTime = lyrics.indices.contains(i + 1) ? lyrics[i + 1].time : .infinity
            if elapsed + 0.25 >= start && elapsed + 0.25 < nextTime {
                return i
            }
        }

        // 全量扫描：取最后一个 time <= elapsed + 0.25 的行（0.25s 前瞻让高亮更早一步，更跟手）。
        var idx: Int?
        for (i, line) in lyrics.enumerated() {
            if line.time <= elapsed + 0.25 { idx = i } else { break }
        }
        return idx
    }

    /// 给定某行索引与播放头，算该行内 0..1 进度（卡拉OK 逐字填充用）。
    /// 与 `NowPlayingModel.currentLyricProgress` 同逻辑，但用传入的 `elapsed` 与歌词/时长，
    /// 便于脱离模型实例做单测。
    public static func progress(
        for index: Int?,
        elapsed: Double,
        lyrics: [LyricLine],
        duration: Double
    ) -> Double {
        guard let i = index, lyrics.indices.contains(i) else { return 0 }
        let start = lyrics[i].time
        let end = lyrics.indices.contains(i + 1) ? lyrics[i + 1].time : (duration > start ? duration : start + 5)
        let span = max(end - start, 0.5)
        return min(max((elapsed - start) / span, 0), 1)
    }
}
