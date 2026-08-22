import Testing
import CanopyKit

/// 歌词索引的核心回归测试。
///
/// 原始 bug：同一首歌循环重播、或拖动进度条往回拖时，歌词停止更新、只有重新播放才恢复。
/// 根因是 `updateLyricIndex` 的「快速路径」只校验了上界（下一行时间），没校验下界（当前行
/// 起始时间）——播放头回退到当前行之前时，被误判成「仍在本行」→ 索引卡死。
/// 修复后该逻辑抽到纯函数 `LyricsIndex.compute`，本文件即对其做穷尽锁定。
struct LyricsIndexTests {

    /// 四行歌词，时间 [0, 5, 10, 15]，时长 20s。
    private func sampleLyrics() -> [LyricLine] {
        [
            .init(time: 0, text: "line 0"),
            .init(time: 5, text: "line 1"),
            .init(time: 10, text: "line 2"),
            .init(time: 15, text: "line 3"),
        ]
    }

    // MARK: - 核心回归：循环重播 / 进度条回拖

    @Test("单曲循环回到开头：索引必须回退到首行，不能卡在末行")
    func singleLoopBackToStart() {
        let lyrics = sampleLyrics()
        // 播放到接近结尾，索引停在末行（idx 3）。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 16, currentIndex: 3) == 3)
        // 歌曲循环：elapsed 瞬间跳回 0。旧实现会卡在 3（误判仍在本行），修复后应为 0。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 0, currentIndex: 3) == 0)
    }

    @Test("进度条往回拖（mid-song）：索引必须回退，不能卡在当前行")
    func seekBackwardMidSong() {
        let lyrics = sampleLyrics()
        // 当前在第 2 行（time 10），播放头在 12s。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 12, currentIndex: 2) == 2)
        // 往回拖到 3s：旧实现只判上界（3.25 < 15）会卡在 2；修复后应回退到首行 0。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 3, currentIndex: 2) == 0)
    }

    @Test("进度条往前拖（mid-song）：索引必须前进到对应行")
    func seekForwardMidSong() {
        let lyrics = sampleLyrics()
        // 当前在第 0 行，播放头 1s；瞬间拖到 13s。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 1, currentIndex: 0) == 0)
        // 13.25 落在第 2 行（time 10）与第 3 行（time 15）之间 → 第 2 行。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 13, currentIndex: 0) == 2)
    }

    @Test("同曲重复播放（replay）：第二次从头开始时索引回到首行")
    func sameTrackReplay() {
        let lyrics = sampleLyrics()
        // 第一次播完：elapsed 19 → idx 3。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 19, currentIndex: 3) == 3)
        // 再次点击播放，elapsed 归零。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 0, currentIndex: 3) == 0)
    }

    // MARK: - 下界边界：本 bug 的精确判定线

    @Test("下界边界：播放头刚退到当前行起始之前，必须立即失效快速路径并回退")
    func lowerBoundJustBeforeStart() {
        let lyrics = sampleLyrics()
        // 当前第 2 行（time 10）。elapsed 9.0 → elapsed+0.25 = 9.25 < 10（下界不满足）。
        // 旧实现（无下界校验）会卡在 2；修复后应回退到第 1 行（time 5）。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 9.0, currentIndex: 2) == 1)
        // 再往前到 4.9：elapsed+0.25 = 5.15，此时第 1 行（time 5）仍在区间 → 停在第 1 行。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 4.9, currentIndex: 2) == 1)
    }

    @Test("下界边界：播放头仍在当前行内时快速路径生效，索引不变")
    func lowerBoundInsideLine() {
        let lyrics = sampleLyrics()
        // 当前第 1 行（time 5），elapsed 6 → 6.25 ∈ [5, 10) → 保持 1。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 6, currentIndex: 1) == 1)
        // 当前第 1 行，elapsed 9.74 → 9.99 ∈ [5, 10) → 保持 1。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 9.74, currentIndex: 1) == 1)
    }

    // MARK: - 上界边界

    @Test("上界边界：播放头刚越过下一行时间，必须前进到下一行")
    func upperBoundCrossesNextLine() {
        let lyrics = sampleLyrics()
        // 当前第 1 行（time 5），下一行 time 10。
        // elapsed 9.74 → 9.99 < 10，快速路径保持 1。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 9.74, currentIndex: 1) == 1)
        // elapsed 9.75 → 10.0 == 下一行时间，扫描取 <= 10.0 的最后一行 = 第 2 行。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 9.75, currentIndex: 1) == 2)
    }

    // MARK: - 正常播放推进

    @Test("正常前向播放：索引随播放头逐行单调递增推进")
    func forwardPlaybackAdvances() {
        let lyrics = sampleLyrics()
        // 注意：compute 内部用 elapsed + 0.25 做前瞻（歌词提前 250ms 高亮更跟手），
        // 所以阈值比行起始时间提前 0.25s。以下 probe 覆盖了每个行切换边界 ±0.2s。
        let probes: [(elapsed: Double, expected: Int?)] = [
            (0, 0),       // 0.25  → [0, 5)  → 0
            (4.7, 0),     // 4.95  → [0, 5)  → 0
            (4.8, 1),     // 5.05  → [5, 10) → 1
            (5.2, 1),     // 5.45  → [5, 10) → 1
            (9.7, 1),     // 9.95  → [5, 10) → 1
            (9.8, 2),     // 10.05 → [10, 15) → 2
            (10.2, 2),    // 10.45 → [10, 15) → 2
            (14.7, 2),    // 14.95 → [10, 15) → 2
            (14.8, 3),    // 15.05 → [15, ∞) → 3
            (15.2, 3),    // 15.45 → [15, ∞) → 3
            (19.9, 3),    // 20.15 → [15, ∞) → 3
        ]
        for (e, expected) in probes {
            #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: e, currentIndex: nil) == expected,
                    "elapsed=\(e) 应为 \(String(describing: expected))")
        }
    }

    // MARK: - 末行 / 空歌词 / 脏索引

    @Test("末行（无下一行）：播放头在末行区间内保持末行，直到歌曲结束")
    func lastLinePersists() {
        let lyrics = sampleLyrics()
        // 当前末行（time 15），elapsed 18 → 18.25 ∈ [15, ∞) → 保持 3。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 18, currentIndex: 3) == 3)
        // elapsed 19.9 仍在末行。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 19.9, currentIndex: 3) == 3)
    }

    @Test("空歌词：始终返回 nil，且不会因脏索引崩溃")
    func emptyLyricsReturnsNil() {
        #expect(LyricsIndex.compute(lyrics: [], elapsed: 5, currentIndex: nil) == nil)
        #expect(LyricsIndex.compute(lyrics: [], elapsed: 5, currentIndex: 2) == nil)
    }

    @Test("空文本行仍按时间建立索引（模型层再决定是否隐藏该行文字）")
    func emptyLastLineStillIndexed() {
        let lyrics = [
            LyricLine(time: 0, text: "有词"),
            LyricLine(time: 5, text: ""),
        ]
        // elapsed 6 → 6.25 >= 5 → 索引为第 1 行（即便其文字为空）。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 6, currentIndex: nil) == 1)
    }

    @Test("切歌后脏索引越界：自动忽略并重新全量扫描")
    func staleIndexOnTrackChange() {
        // 旧歌 5 行，索引曾到 5；新歌只有 2 行。
        let newLyrics = [
            LyricLine(time: 0, text: "new 0"),
            LyricLine(time: 4, text: "new 1"),
        ]
        // currentIndex 5 对新歌越界 → 跳过快速路径 → 扫描 elapsed 3 落在第 0 行。
        #expect(LyricsIndex.compute(lyrics: newLyrics, elapsed: 3, currentIndex: 5) == 0)
    }

    @Test("暂停/恢复（elapsed 不变）：快速路径保持原索引")
    func pauseResumeStaysPut() {
        let lyrics = sampleLyrics()
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 7, currentIndex: 1) == 1)
        // 「恢复」后再调一次，elapsed 仍是 7 → 仍是 1。
        #expect(LyricsIndex.compute(lyrics: lyrics, elapsed: 7, currentIndex: 1) == 1)
    }
}
