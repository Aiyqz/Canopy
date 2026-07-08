import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: Double      // seconds
    let text: String
}

/// Fetches time-synced lyrics from LRCLIB (lrclib.net) — a free, open,
/// no-API-key community lyrics database that returns standard LRC data.
enum LyricsService {
    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    /// Public entry: returns time-synced lyric lines, or a plain-lyrics
    /// fallback (evenly distributed across the track) if no synced version exists.
    static func fetchSynced(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        guard !title.isEmpty, !artist.isEmpty else { return [] }

        // 1) Exact match via /api/get (no album — strict album match causes 404s).
        if let lines = await requestGet(track: title, artist: artist, duration: duration), !lines.isEmpty {
            return simplify(lines)
        }
        // 2) Fuzzy /api/search — pick the entry whose duration is closest.
        if let lines = await requestSearch(track: title, artist: artist, duration: duration), !lines.isEmpty {
            return simplify(lines)
        }
        return []
    }

    // MARK: - 繁体 → 简体

    /// LRCLIB 的华语歌词多为繁体（孙燕姿 / 苏打绿等），用 macOS 原生
    /// CFStringTransform 转成简体，无需任何第三方依赖。
    private static func toSimplified(_ text: String) -> String {
        TraditionalSimplified.convert(text)
    }

    private static func simplify(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map { LyricLine(time: $0.time, text: toSimplified($0.text)) }
    }

    // MARK: - Network (写死路由器代理 + 重试 + 长超时)

    // 写死路由器代理（ImmortalWrt，xray 监听所有接口）：
    //   HTTP: 192.168.10.1:20171 / SOCKS5: 192.168.10.1:20170
    // LRCLIB 服务器在海外，直连经常超时，走代理才能稳定拉到歌词。
    private static let proxyHost = "192.168.10.1"
    private static let proxyPortHTTP = 20171
    private static let proxyPortSOCKS = 20170

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": proxyHost,
            "HTTPPort": proxyPortHTTP,
            "SOCKSEnable": 1,
            "SOCKSProxy": proxyHost,
            "SOCKSPort": proxyPortSOCKS,
        ] as [String: Any]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func fetchData(_ url: URL) async throws -> Data {
        var lastErr: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
            }
            var req = URLRequest(url: url)
            req.setValue("Canopy/1.0 (macOS notch app; github.com/canopy)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    return data
                }
                lastErr = URLError(.badServerResponse)
            } catch {
                lastErr = error
            }
        }
        throw lastErr
    }

    private static func requestGet(track: String, artist: String, duration: Double) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = comps?.url else { return nil }
        guard let data = try? await fetchData(url) else { return nil }
        guard let dec = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let lrc = dec.syncedLyrics, !lrc.isEmpty { return parseLRC(lrc) }
        if let plain = dec.plainLyrics, !plain.isEmpty { return parsePlain(plain, duration: duration) }
        return nil
    }

    private static func requestSearch(track: String, artist: String, duration: Double) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps?.url else { return nil }
        guard let data = try? await fetchData(url) else { return nil }
        guard let results = try? JSONDecoder().decode([Response].self, from: data) else { return nil }

        // Prefer the synced entry whose duration is closest to the playing track.
        let synced = results
            .filter { ($0.syncedLyrics ?? "").isEmpty == false }
            .min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        if let synced, let lrc = synced.syncedLyrics, !lrc.isEmpty {
            return parseLRC(lrc)
        }
        // Fallback: any plain lyrics, distributed evenly across the track.
        if let plain = results.first(where: { !($0.plainLyrics ?? "").isEmpty })?.plainLyrics {
            return parsePlain(plain, duration: duration)
        }
        return nil
    }

    // MARK: - Parsing

    /// Parses LRC text ("[mm:ss.xx] line") into time-sorted lyric lines.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let tagPattern = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

        for raw in lrc.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            let ns = line as NSString
            guard let regex = tagPattern else { continue }
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)

            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                let fracRange = m.range(at: 3)
                if fracRange.location != NSNotFound {
                    let fracStr = ns.substring(with: fracRange)
                    fraction = (Double(fracStr) ?? 0) / pow(10, Double(fracStr.count))
                }
                let time = minutes * 60 + seconds + fraction
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Distributes plain (unsynced) lyrics evenly across the track duration
    /// so they still scroll in time even without timestamps.
    static func parsePlain(_ text: String, duration: Double) -> [LyricLine] {
        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, duration > 0 else { return [] }
        let per = duration / Double(lines.count)
        return lines.enumerated().map { offset, element in
            LyricLine(time: per * Double(offset), text: element)
        }
    }
}
