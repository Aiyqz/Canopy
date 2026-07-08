import Foundation
import CommonCrypto
import CryptoKit

// MARK: - 歌词行模型

/// 一行时间同步歌词。
struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: Double      // 起始时间（秒）
    let text: String
}

// MARK: - 歌词来源协议

/// 统一的歌词来源接口：每个来源都实现 `fetch`，返回按时间排序的歌词行（为空表示没找到）。
protocol LyricsSource {
    var name: String { get }
    /// 根据曲目信息拉取同步歌词；失败或为空返回 nil。
    func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine]?
}

// MARK: - 网络基类（重试 / 限流）

/// 通用网络工具：带指数退避的重试，遇到 HTTP 429（限流）或 5xx 会自动退避后重试。
enum Net {
    /// 最多重试 `maxAttempts` 次，第 1 次立即尝试，之后按 2^n × 0.5s 退避。
    static func withRetry<T>(maxAttempts: Int = 3, _ body: () async throws -> T) async -> T? {
        for attempt in 0..<maxAttempts {
            do {
                return try await body()
            } catch {
                // 429 / 服务端错误 → 退避；其他错误同样退避，避免无效高频重试
                if attempt < maxAttempts - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt + 1))) * 500_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        return nil
    }

    /// 发起请求并返回 body；非 2xx 抛出 `NetError.http(status)`（便于上层判断是否限流）。
    static func request(_ req: URLRequest, session: URLSession) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                // 429 = 请求过多（限流），其余非 2xx 也按失败处理
                throw NetError.http(http.statusCode)
            }
        }
        return data
    }
}

enum NetError: Error {
    case http(Int)
}

// MARK: - LRCLIB 来源（海外，走路由器代理）

/// LRCLIB (lrclib.net)：免费、开放、无需 API key 的社区歌词库，返回标准 LRC。
/// 服务器在海外，直连经常超时，因此走写死的路由器代理。
struct LRCLIBSource: LyricsSource {
    let name = "LRCLIB"

    // 写死路由器代理（ImmortalWrt，xray 监听所有接口）：
    //   HTTP: 192.168.10.1:20171 / SOCKS5: 192.168.10.1:20170
    private let proxyHost = "192.168.10.1"
    private let proxyPortHTTP = 20171
    private let proxyPortSOCKS = 20170

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": "192.168.10.1",
            "HTTPPort": 20171,
            "SOCKSEnable": 1,
            "SOCKSProxy": "192.168.10.1",
            "SOCKSPort": 20170,
        ] as [String: Any]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine]? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        if let lines = await requestGet(track: title, artist: artist, duration: duration), !lines.isEmpty {
            return lines
        }
        if let lines = await requestSearch(track: title, artist: artist, duration: duration), !lines.isEmpty {
            return lines
        }
        return nil
    }

    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    private func fetchData(_ url: URL) async throws -> Data {
        guard let data = await Net.withRetry({
            var req = URLRequest(url: url)
            req.setValue("Canopy/1.0 (macOS notch app; github.com/canopy)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            return try await Net.request(req, session: session)
        }) else {
            throw NetError.http(0)
        }
        return data
    }

    private func requestGet(track: String, artist: String, duration: Double) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = comps?.url else { return nil }
        guard let data = try? await fetchData(url) else { return nil }
        guard let dec = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let lrc = dec.syncedLyrics, !lrc.isEmpty { return LyricsService.parseLRC(lrc) }
        if let plain = dec.plainLyrics, !plain.isEmpty { return LyricsService.parsePlain(plain, duration: duration) }
        return nil
    }

    private func requestSearch(track: String, artist: String, duration: Double) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps?.url else { return nil }
        guard let data = try? await fetchData(url) else { return nil }
        guard let results = try? JSONDecoder().decode([Response].self, from: data) else { return nil }

        // 优先选时长最接近的那条同步歌词
        let synced = results
            .filter { ($0.syncedLyrics ?? "").isEmpty == false }
            .min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        if let synced, let lrc = synced.syncedLyrics, !lrc.isEmpty {
            return LyricsService.parseLRC(lrc)
        }
        if let plain = results.first(where: { !($0.plainLyrics ?? "").isEmpty })?.plainLyrics {
            return LyricsService.parsePlain(plain, duration: duration)
        }
        return nil
    }
}

// MARK: - 网易云音乐来源（国内，直连，eapi 加密）

/// 网易云音乐：搜索 + 拉歌词均走 eapi 接口（AES-128-ECB 加密，无需 RSA）。
/// 国内服务，直连即可，不走海外代理。
struct NeteaseSource: LyricsSource {
    let name = "网易云音乐"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 显式关闭代理，保证国内音源直连，不被路由器的海外 xray 节点拖累
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine]? {
        guard !title.isEmpty else { return nil }
        // 1) 搜索拿到 song id
        guard let songId = await searchId(keyword: "\(title) \(artist)".trimmingCharacters(in: .whitespaces),
                                          title: title, artist: artist, duration: duration) else { return nil }
        // 2) 用 id 拉歌词
        guard let lrc = await fetchLyric(songId: songId) else { return nil }
        let lines = LyricsService.parseLRC(lrc)
        return lines.isEmpty ? nil : lines
    }

    // MARK: 搜索

    private func searchId(keyword: String, title: String, artist: String, duration: Double) async -> String? {
        let url = "https://interface.music.163.com/eapi/cloudsearch/pc"
        let data: [String: String] = [
            "s": keyword,
            "type": "1",
            "limit": "10",
            "offset": "0",
            "total": "true"
        ]
        guard let body = try? await eapiRequest(url: url, params: data),
              let resp = try? JSONDecoder().decode(NeteaseSearchResp.self, from: body) else { return nil }
        guard let songs = resp.result?.songs, !songs.isEmpty else { return nil }
        let pick = bestMatch(
            items: songs,
            title: title, artist: artist, duration: duration,
            getName: { $0.name },
            getArtist: { ($0.ar ?? []).map { $0.name }.joined(separator: " ") },
            getDuration: { Double($0.dt ?? 0) / 1000 }
        )
        return pick?.id
    }

    // MARK: 拉歌词

    private func fetchLyric(songId: String) async -> String? {
        let url = "https://interface3.music.163.com/eapi/song/lyric/v1"
        let data: [String: String] = [
            "id": songId,
            "cp": "false",
            "lv": "0",
            "kv": "0",
            "tv": "0",
            "rv": "0",
            "yv": "0",
            "ytv": "0",
            "yrv": "0",
            "csrf_token": ""
        ]
        guard let body = try? await eapiRequest(url: url, params: data),
              let resp = try? JSONDecoder().decode(NeteaseLyricResp.self, from: body) else { return nil }
        return resp.lrc?.lyric?.isEmpty == false ? resp.lrc?.lyric : nil
    }

    // MARK: eapi 请求封装

    /// 构造并发送 eapi 请求：AES-ECB 加密 params，附带安卓端头与 Cookie。
    private func eapiRequest(url: String, params: [String: String]) async throws -> Data {
        // 请求头里需要的 header 字段（会一并塞进加密报文的 header 中）
        let ts = Int(Date().timeIntervalSince1970)
        let header: [String: String] = [
            "__csrf": "",
            "appver": "8.0.0",
            "buildver": String(ts),
            "channel": "",
            "deviceId": "",
            "mobilename": "",
            "resolution": "1920x1080",
            "os": "android",
            "osver": "",
            "requestId": "\(ts)_\(String(format: "%04d", Int.random(in: 0..<1000)))",
            "versioncode": "140",
            "MUSIC_U": ""
        ]
        var params = params
        if let headerJson = try? JSONSerialization.data(withJSONObject: header),
           let headerStr = String(data: headerJson, encoding: .utf8) {
            params["header"] = headerStr
        }
        let enc = NeteaseCrypto.eapi(url: url, params: params)

        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Linux; Android 9; PCT-AL10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.64 HuaweiBrowser/10.0.3.311 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(header.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        req.httpBody = "params=\(enc)".data(using: .utf8)

        guard let data = await Net.withRetry({ try await Net.request(req, session: session) }) else {
            throw NetError.http(0)
        }
        return data
    }
}

// MARK: - 网易云 eapi 加密（AES-128-ECB + PKCS7，结果转十六进制大写）

enum NeteaseCrypto {
    /// 还原 Lyricify 的 eapi 加密流程，返回十六进制大写字符串。
    static func eapi(url: String, params: [String: String]) -> String {
        // 1) 还原接口真实路径（去掉域名前缀）
        let path = url
            .replacingOccurrences(of: "https://interface3.music.163.com/e", with: "/")
            .replacingOccurrences(of: "https://interface.music.163.com/e", with: "/")
        // 2) 构造报文：nobody{path}use{json}md5forencrypt
        let text = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let message = "nobody\(path)use\(text)md5forencrypt"
        let digest = md5Hex(message)
        let payload = "\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        // 3) AES-ECB 加密后转十六进制大写
        guard let data = payload.data(using: .utf8),
              let enc = aesECB(data, key: "e82ckenh8dichen8") else { return "" }
        return enc.map { String(format: "%02X", $0) }.joined()
    }

    private static func md5Hex(_ s: String) -> String {
        guard let data = s.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func aesECB(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8), keyData.count == 16 else { return nil }
        var outLength = 0
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let status = data.withUnsafeBytes { dataBytes in
            keyData.withUnsafeBytes { keyBytes in
                out.withUnsafeMutableBytes { outBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(0),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyData.count, nil,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outBytes.count, &outLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(outLength))
    }
}

// MARK: - 网易云响应解析

private struct NeteaseSearchResp: Decodable {
    struct Result: Decodable {
        struct Song: Decodable {
            let id: String
            let name: String
            struct Ar: Decodable { let name: String }
            let ar: [Ar]?
            let dt: Int?   // 时长（毫秒）
        }
        let songs: [Song]?
    }
    let result: Result?
}

private struct NeteaseLyricResp: Decodable {
    struct Lyrics: Decodable { let lyric: String? }
    let lrc: Lyrics?
    let code: Int?
}

// MARK: - QQ 音乐来源（国内，直连，base64 歌词）

/// QQ 音乐：搜索走 musicu.fcg，歌词走 fcg_query_lyric（返回 base64 编码的 LRC）。
/// 国内服务，直连即可。
struct QQMusicSource: LyricsSource {
    let name = "QQ音乐"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine]? {
        guard !title.isEmpty else { return nil }
        guard let mid = await searchMid(keyword: "\(title) \(artist)".trimmingCharacters(in: .whitespaces),
                                        title: title, artist: artist, duration: duration) else { return nil }
        guard let lrc = await fetchLyric(songMid: mid) else { return nil }
        let lines = LyricsService.parseLRC(lrc)
        return lines.isEmpty ? nil : lines
    }

    // MARK: 搜索

    private func searchMid(keyword: String, title: String, artist: String, duration: Double) async -> String? {
        let url = "https://u.y.qq.com/cgi-bin/musicu.fcg"
        let body: [String: Any] = [
            "req_1": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "num_per_page": "20",
                    "page_num": "1",
                    "query": keyword,
                    "search_type": 0
                ]
            ]
        ]
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let data = await Net.withRetry({ try await Net.request(req, session: session) }),
              let resp = try? JSONDecoder().decode(QQSearchResp.self, from: data),
              let list = resp.req_1.data.body.song.list, !list.isEmpty else { return nil }
        let pick = bestMatch(
            items: list,
            title: title, artist: artist, duration: duration,
            getName: { $0.name },
            getArtist: { ($0.singer ?? []).map { $0.name }.joined(separator: " ") },
            getDuration: { _ in nil }
        )
        return pick?.mid
    }

    // MARK: 拉歌词

    private func fetchLyric(songMid: String) async -> String? {
        let url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
        let pcache = Int(Date().timeIntervalSince1970 * 1000)
        let fields: [String: String] = [
            "callback": "MusicJsonCallback_lrc",
            "pcachetime": String(pcache),
            "songmid": songMid,
            "g_tk": "5381",
            "jsonpCallback": "MusicJsonCallback_lrc",
            "loginUin": "0",
            "hostUin": "0",
            "format": "jsonp",
            "inCharset": "utf8",
            "outCharset": "utf8",
            "notice": "0",
            "platform": "yqq",
            "needNewCode": "0"
        ]
        var comps = URLComponents(string: url)
        comps?.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let reqUrl = comps?.url else { return nil }
        var req = URLRequest(url: reqUrl)
        req.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")

        guard let data = await Net.withRetry({ try await Net.request(req, session: session) }),
              var s = String(data: data, encoding: .utf8) else { return nil }
        // 去掉 JSONP 包裹：MusicJsonCallback_lrc({...})
        if let r = s.range(of: "MusicJsonCallback_lrc(") { s = String(s[r.upperBound...]) }
        if s.hasSuffix(")") { s.removeLast() }
        guard let jsonData = s.data(using: .utf8),
              let resp = try? JSONDecoder().decode(QQLyricResp.self, from: jsonData),
              let b64 = resp.lyric, !b64.isEmpty,
              let lrcData = Data(base64Encoded: b64),
              let lrc = String(data: lrcData, encoding: .utf8) else { return nil }
        return lrc
    }
}

// MARK: - QQ 音乐响应解析

private struct QQSearchResp: Decodable {
    struct Req1: Decodable {
        struct Data: Decodable {
            struct Body: Decodable {
                struct Song: Decodable {
                    struct Item: Decodable {
                        let mid: String
                        let name: String
                        struct Singer: Decodable { let name: String }
                        let singer: [Singer]?
                    }
                    let list: [Item]?
                }
                let song: Song
            }
            let body: Body
        }
        let data: Data
    }
    let req_1: Req1
}

private struct QQLyricResp: Decodable {
    let code: Int?
    let lyric: String?   // base64 编码的 LRC
    let trans: String?
}

// MARK: - 通用匹配工具

/// 从搜索结果中挑选最匹配的曲目：标题相似 + 艺人包含 + 时长接近，综合打分取最高。
func bestMatch<T>(items: [T], title: String, artist: String, duration: Double,
                  getName: (T) -> String,
                  getArtist: (T) -> String,
                  getDuration: (T) -> Double?) -> T? {
    let t = title.lowercased().trimmingCharacters(in: .whitespaces)
    let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
    var best: (item: T, score: Int)?
    for item in items {
        let name = getName(item).lowercased().trimmingCharacters(in: .whitespaces)
        let art = getArtist(item).lowercased()
        var score = 0
        if name == t || name.contains(t) || t.contains(name) { score += 2 }
        if !a.isEmpty && (art.contains(a) || a.contains(art)) { score += 1 }
        if let d = getDuration(item), duration > 0, abs(d - duration) < 8 { score += 1 }
        if score > (best?.score ?? -1) { best = (item, score) }
    }
    return best?.item
}

// MARK: - 协调器（来源回退链）

/// 多音源协调器：按优先级依次尝试，返回第一个非空结果。
/// 顺序：LRCLIB（海外）→ 网易云（国内）→ QQ音乐（国内）。
struct LyricsFetcher {
    static let sources: [any LyricsSource] = [
        LRCLIBSource(),
        NeteaseSource(),
        QQMusicSource()
    ]

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        for source in sources {
            if let lines = await source.fetch(title: title, artist: artist, album: album, duration: duration),
               !lines.isEmpty {
                return lines
            }
        }
        return []
    }
}

// MARK: - 公开入口

/// 从多个音源拉取时间同步歌词，并统一做繁→简转换。
/// 失败时返回空数组（UI 层据此隐藏歌词）。
enum LyricsService {
    /// 公开入口：优先返回时间同步歌词；若全部来源都没有，返回空数组。
    static func fetchSynced(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        let raw = await LyricsFetcher.fetch(title: title, artist: artist, album: album, duration: duration)
        // 统一做繁体→简体（华语歌词常出现繁体，转换后更顺眼；对简体/英文无副作用）
        return raw.map { LyricLine(time: $0.time, text: TraditionalSimplified.convert($0.text)) }
    }

    // MARK: - 解析

    /// 解析 LRC 文本（"[mm:ss.xx] 歌词"）为按时间排序的歌词行。
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

    /// 把纯文本（无时间戳）歌词在整首歌时长内均匀铺开，
    /// 这样即使没有时间戳也能随播放进度滚动。
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
