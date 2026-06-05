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
    }

    static func fetchSynced(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        guard !title.isEmpty, !artist.isEmpty else { return [] }

        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = comps?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Canopy/1.0 (macOS notch app; github.com/canopy)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Fall back to the fuzzy /search endpoint if exact match misses.
                return await searchSynced(title: title, artist: artist)
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if let lrc = decoded.syncedLyrics, !lrc.isEmpty {
                return parseLRC(lrc)
            }
            return []
        } catch {
            return []
        }
    }

    private static func searchSynced(title: String, artist: String) async -> [LyricLine] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Canopy/1.0 (macOS notch app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let results = try JSONDecoder().decode([Response].self, from: data)
            if let first = results.first(where: { ($0.syncedLyrics ?? "").isEmpty == false }),
               let lrc = first.syncedLyrics {
                return parseLRC(lrc)
            }
            return []
        } catch {
            return []
        }
    }

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
}
