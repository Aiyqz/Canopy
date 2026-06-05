import Foundation

/// Fallback now-playing source that talks to Music and Spotify over Apple
/// events, used when the MediaRemote adapter isn't available. Reads and controls
/// playback via `/usr/bin/osascript` (kept off the main thread, and avoids the
/// main-thread requirements of in-process NSAppleScript). Artwork isn't fetched
/// here — the palette falls back to its default gradient.
final class AppleScriptMedia {
    /// The app we last saw with active playback, so commands target the right one.
    private var activeApp = "Music"
    private let queue = DispatchQueue(label: "pro.getcanopy.applescript")

    // Reads the first running player that is playing or paused.
    private static let readScript = """
    set out to ""
    if application "Music" is running then
      tell application "Music"
        set st to (player state as text)
        if st is "playing" or st is "paused" then
          set t to current track
          set out to "Music" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & (player position) & tab & st
        end if
      end tell
    end if
    if out is "" and application "Spotify" is running then
      tell application "Spotify"
        set st to (player state as text)
        if st is "playing" or st is "paused" then
          set t to current track
          set out to "Spotify" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & (player position) & tab & st
        end if
      end tell
    end if
    return out
    """

    func snapshot(_ completion: @escaping (NowPlayingSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            guard let line = Self.runOSAScript(Self.readScript)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                completion(nil); return
            }
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 7 else { completion(nil); return }

            self.activeApp = parts[0]
            var s = NowPlayingSnapshot()
            s.title  = parts[1]
            s.artist = parts[2]
            s.album  = parts[3]
            s.duration  = Self.number(parts[4])
            s.elapsed   = Self.number(parts[5])
            s.isPlaying = parts[6] == "playing"
            s.timestamp = Date()
            s.carriedArtwork = false
            completion(s)
        }
    }

    func send(_ command: MediaCommand) {
        let app = activeApp
        let verb: String
        switch command {
        case .play:            verb = "play"
        case .pause:           verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .stop:            verb = "pause"
        case .nextTrack:       verb = "next track"
        case .previousTrack:   verb = "previous track"
        }
        queue.async { _ = Self.runOSAScript("tell application \"\(app)\" to \(verb)") }
    }

    func seek(toTime seconds: Double) {
        let app = activeApp
        let pos = Int(max(0, seconds))
        queue.async {
            _ = Self.runOSAScript("tell application \"\(app)\" to set player position to \(pos)")
        }
    }

    // MARK: Helpers

    private static func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// osascript prints numbers in the system locale; tolerate a comma separator.
    private static func number(_ raw: String) -> Double {
        Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
