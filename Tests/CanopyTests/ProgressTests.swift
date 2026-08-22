import Testing
import CanopyKit

/// 卡拉OK「逐字填充」进度（LyricsIndex.progress）的纯函数测试。
/// 该逻辑原先是 NowPlayingModel 的实例方法，现已抽到 LyricsIndex.progress 便于单测。
struct ProgressTests {

    private func lines() -> [LyricLine] {
        [.init(time: 0, text: "a"), .init(time: 10, text: "b")]
    }

    private func approx(_ actual: Double, _ expected: Double, eps: Double = 1e-9) -> Bool {
        abs(actual - expected) < eps
    }

    @Test("行内中点：进度应为 0.5")
    func withinLineMidpoint() {
        let p = LyricsIndex.progress(for: 0, elapsed: 5, lyrics: lines(), duration: 20)
        #expect(approx(p, 0.5))
    }

    @Test("行起始：进度为 0")
    func atLineStart() {
        let p = LyricsIndex.progress(for: 0, elapsed: 0, lyrics: lines(), duration: 20)
        #expect(approx(p, 0))
    }

    @Test("越过行尾：进度夹到 1（不会超过 100%）")
    func pastLineEndClamped() {
        // 第 0 行 [0,10)，elapsed 12 → (12-0)/10 = 1.2 → 夹到 1。
        let p = LyricsIndex.progress(for: 0, elapsed: 12, lyrics: lines(), duration: 20)
        #expect(approx(p, 1))
    }

    @Test("播放头早于行起始：进度夹到 0（不会变成负数）")
    func beforeLineStartClamped() {
        // 第 1 行 time 10，elapsed 8 → (8-10)/10 = -0.2 → 夹到 0。
        let p = LyricsIndex.progress(for: 1, elapsed: 8, lyrics: lines(), duration: 20)
        #expect(approx(p, 0))
    }

    @Test("末行无下一行且时长小于行时间：用 start+5 兜底跨度")
    func lastLineBeyondDuration() {
        // 仅 2 行，时长却给 5（异常短）。第 1 行 time 10：end = duration(5) > 10? 否 → start+5 = 15。
        // 跨度 = 5，elapsed 12 → (12-10)/5 = 0.4。
        let p = LyricsIndex.progress(for: 1, elapsed: 12, lyrics: lines(), duration: 5)
        #expect(approx(p, 0.4))
    }

    @Test("索引为 nil 或越界：进度返回 0")
    func invalidIndex() {
        #expect(approx(LyricsIndex.progress(for: nil, elapsed: 5, lyrics: lines(), duration: 20), 0))
        #expect(approx(LyricsIndex.progress(for: 9, elapsed: 5, lyrics: lines(), duration: 20), 0))
    }

    @Test("极短行（<=0.5s）跨度下限保护，避免除零/爆炸")
    func tinySpanClamped() {
        let tiny = [LyricLine(time: 0, text: "x"), LyricLine(time: 0.1, text: "y")]
        // 第 0 行跨度被 max(0.1, 0.5) = 0.5 兜底；elapsed 0.05 → 0.05/0.5 = 0.1。
        let p = LyricsIndex.progress(for: 0, elapsed: 0.05, lyrics: tiny, duration: 20)
        #expect(approx(p, 0.1))
    }
}
