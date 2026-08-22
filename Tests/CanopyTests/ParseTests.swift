import Testing
import CanopyKit

/// 纯函数解析 / 匹配 / 繁简转换的回归测试（不依赖网络与 UI）。
struct ParseTests {

    // MARK: - parseLRC

    @Test("标准 LRC：正确解析并按时间排序")
    func parseLRCStandard() {
        let lrc = """
        [00:01.00]First
        [00:02.50]Second
        [00:03.00]Third
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.map { $0.time } == [1.0, 2.5, 3.0])
        #expect(lines.map { $0.text } == ["First", "Second", "Third"])
    }

    @Test("LRC 乱序输入：结果仍按时间升序")
    func parseLRCUnsortedInput() {
        let lrc = """
        [00:03.00]Third
        [00:01.00]First
        [00:02.00]Second
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.map { $0.time } == [1.0, 2.0, 3.0])
    }

    @Test("一行多时间戳：展开为多行同名歌词")
    func parseLRCMultipleTimestamps() {
        let lrc = "[00:01.00][00:05.00]Repeat"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 2)
        #expect(lines.map { $0.time }.sorted() == [1.0, 5.0])
        #expect(lines.allSatisfy { $0.text == "Repeat" })
    }

    @Test("无标签行被忽略，尾随空白被裁剪")
    func parseLRCIgnoresUntagged() {
        let lrc = """
        [00:01.00]  First with spaces
        纯文本没有时间戳会被丢弃
        [00:02.00]Second
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].text == "First with spaces") // 首部/尾部空白裁剪
        #expect(lines[1].text == "Second")
    }

    @Test("毫秒位数自适应：2 位与 3 位 fraction 都正确")
    func parseLRCFractionDigits() {
        let lrc = "[00:01.50]TwoDigit\n[00:02.500]ThreeDigit"
        let lines = LyricsService.parseLRC(lrc)
        #expect(approx(lines[0].time, 1.5))
        #expect(approx(lines[1].time, 2.5))
    }

    // MARK: - parsePlain

    @Test("纯文本：在整首时长内均匀铺开")
    func parsePlainDistributes() {
        let text = "a\nb\nc"
        let lines = LyricsService.parsePlain(text, duration: 30)
        #expect(lines.map { $0.time } == [0, 10, 20])
        #expect(lines.map { $0.text } == ["a", "b", "c"])
    }

    @Test("纯文本为空或时长为 0：返回空数组")
    func parsePlainEmpty() {
        #expect(LyricsService.parsePlain("", duration: 30) == [])
        #expect(LyricsService.parsePlain("a\nb", duration: 0) == [])
    }

    @Test("纯文本空行被过滤")
    func parsePlainDropsBlankLines() {
        let text = "a\n\n\nb"
        let lines = LyricsService.parsePlain(text, duration: 20)
        #expect(lines.map { $0.text } == ["a", "b"])
        #expect(lines.map { $0.time } == [0, 10])
    }

    // MARK: - bestMatch

    private struct Song {
        let name: String
        let artist: String
        let dur: Double?
    }

    @Test("bestMatch：标题+艺人精确命中优先")
    func bestMatchTitleArtist() {
        let items = [
            Song(name: "Hello", artist: "Adele", dur: 200),
            Song(name: "Hello", artist: "Someone Else", dur: 210),
        ]
        let pick = bestMatch(
            items: items, title: "Hello", artist: "Adele", duration: 200,
            getName: { $0.name }, getArtist: { $0.artist }, getDuration: { $0.dur }
        )
        #expect(pick?.artist == "Adele")
    }

    @Test("bestMatch：艺人相同时按时长接近度优选")
    func bestMatchDurationTiebreak() {
        let items = [
            Song(name: "Hello", artist: "Adele", dur: 180),
            Song(name: "Hello", artist: "Adele", dur: 205),
        ]
        let pick = bestMatch(
            items: items, title: "Hello", artist: "Adele", duration: 200,
            getName: { $0.name }, getArtist: { $0.artist }, getDuration: { $0.dur }
        )
        #expect(pick?.dur == 205)
    }

    @Test("bestMatch：无匹配返回 nil")
    func bestMatchNone() {
        let items = [Song(name: "X", artist: "Y", dur: nil)]
        let pick = bestMatch(
            items: items, title: "完全不同", artist: "Z", duration: 100,
            getName: { $0.name }, getArtist: { $0.artist }, getDuration: { $0.dur }
        )
        #expect(pick == nil)
    }

    // MARK: - TraditionalSimplified

    @Test("繁→简：单字转换")
    func tradSimpSingle() {
        #expect(TraditionalSimplified.convert("體") == "体")
    }

    @Test("繁→简：整词转换")
    func tradSimpWord() {
        #expect(TraditionalSimplified.convert("愛你") == "爱你")
        #expect(TraditionalSimplified.convert("這是一首歌") == "这是一首歌")
    }

    @Test("繁→简：已简体/英文/数字保持不变")
    func tradSimpNoop() {
        #expect(TraditionalSimplified.convert("你好 world 123") == "你好 world 123")
        #expect(TraditionalSimplified.convert("Hello, 世界！") == "Hello, 世界！")
    }

    @Test("繁→简：混合句中只转换收录的繁体字符")
    func tradSimpMixed() {
        // 「愛」收录→「爱」；「你」收录→「你」；其余保持。
        #expect(TraditionalSimplified.convert("我愛你 forever") == "我爱你 forever")
    }

    // MARK: - helpers

    private func approx(_ a: Double, _ b: Double, eps: Double = 1e-9) -> Bool {
        abs(a - b) < eps
    }
}
