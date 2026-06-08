import AppKit
import Foundation

/// One now-playing observation, normalized across every backend so the rest of
/// the app never needs to know where the data came from.
struct NowPlayingSnapshot {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0        // seconds (0 = unknown)
    var elapsed: Double = 0         // seconds, sampled at `timestamp`
    var timestamp: Date = Date()    // when `elapsed` was measured
    var artworkData: Data?          // raw image bytes, when this update carried art
    /// Whether this update spoke about artwork at all (so a diff that simply
    /// didn't mention art doesn't clobber the existing image).
    var carriedArtwork: Bool = false

    var isEmpty: Bool { title.isEmpty }
}

enum MediaCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}

/// Resolves and drives a now-playing source. Prefers the bundled
/// ungive/mediaremote-adapter (works on macOS 15.4+, where direct MediaRemote
/// access is otherwise blocked); falls back to the in-process MediaRemote bridge
/// where it still works, and finally to AppleScript control of Music / Spotify.
///
/// The adapter is invoked as `/usr/bin/perl <script> <framework> <command>`; the
/// framework is only ever passed by path and loaded *inside* perl, never linked
/// into Canopy.
@MainActor
final class MediaController {
    enum Backend: String {
        case adapter     = "MediaRemote adapter"
        case mediaRemote = "MediaRemote (direct)"
        case appleScript = "AppleScript (Music / Spotify)"
        case none        = "unavailable"
    }

    private(set) var backend: Backend = .none
    var isAvailable: Bool { backend != .none }

    /// Called on the main actor whenever a fresh snapshot is available.
    var onSnapshot: ((NowPlayingSnapshot) -> Void)?
    /// Called once the launch health check has chosen a backend.
    var onBackendResolved: ((Backend) -> Void)?

    // Adapter resources (nil when not bundled — e.g. fetch-adapter.sh wasn't run).
    private let perlPath = "/usr/bin/perl"
    private let scriptPath: String?
    private let frameworkPath: String?
    private let testClientPath: String?

    private var streamProcess: Process?
    private var lineBuffer = Data()
    private var merged: [String: Any] = [:]

    private let appleScript = AppleScriptMedia()
    private var appleScriptTimer: Timer?

    init() {
        let res = Bundle.main.resourcePath
        func existing(_ name: String) -> String? {
            guard let res else { return nil }
            let p = (res as NSString).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: p) ? p : nil
        }
        scriptPath = existing("mediaremote-adapter.pl")
        frameworkPath = existing("MediaRemoteAdapter.framework")
        testClientPath = existing("MediaRemoteAdapterTestClient")
    }

    // MARK: Lifecycle

    /// Runs the adapter health check off the main thread, then starts the first
    /// backend that works. Order: adapter → direct MediaRemote → AppleScript.
    func start() {
        guard let scriptPath, let frameworkPath else {
            resolveFallback()
            return
        }
        let perl = perlPath
        let testClient = testClientPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.runHealthCheck(
                perl: perl, script: scriptPath, framework: frameworkPath, testClient: testClient
            )
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.backend = .adapter
                    self.onBackendResolved?(.adapter)
                    self.startAdapterStream(script: scriptPath, framework: frameworkPath)
                } else {
                    NSLog("Canopy: MediaRemote adapter health check failed; falling back")
                    self.resolveFallback()
                }
            }
        }
    }

    func stop() {
        streamProcess?.terminationHandler = nil
        streamProcess?.terminate()
        streamProcess = nil
        appleScriptTimer?.invalidate()
        appleScriptTimer = nil
    }

    private func resolveFallback() {
        if MediaRemote.shared.isAvailable {
            backend = .mediaRemote
            onBackendResolved?(.mediaRemote)
            startMediaRemote()
        } else {
            backend = .appleScript
            onBackendResolved?(.appleScript)
            startAppleScriptPolling()
        }
    }

    // MARK: Commands (routed per backend)

    func send(_ command: MediaCommand) {
        switch backend {
        case .adapter:
            runAdapter(["send", "\(command.rawValue)"])
        case .mediaRemote:
            MediaRemote.shared.send(MediaRemote.Command(rawValue: command.rawValue) ?? .togglePlayPause)
        case .appleScript:
            appleScript.send(command)
        case .none:
            break
        }
    }

    func seek(toTime seconds: Double) {
        let t = max(0, seconds)
        switch backend {
        case .adapter:
            runAdapter(["seek", "\(Int(t * 1_000_000))"]) // microseconds
        case .mediaRemote:
            MediaRemote.shared.setElapsed(t)
        case .appleScript:
            appleScript.seek(toTime: t)
        case .none:
            break
        }
    }

    // MARK: Adapter — health check

    /// Returns true if the adapter can actually read media. Uses the `test`
    /// command (definitive, needs the test client) when available, otherwise a
    /// best-effort `get` that must exit 0. Guarded by a watchdog so a wedged
    /// perl can't hang launch.
    nonisolated private static func runHealthCheck(
        perl: String, script: String, framework: String, testClient: String?
    ) -> Bool {
        var args = [script, framework]
        if let testClient { args.append(testClient) }
        args.append(testClient != nil ? "test" : "get")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: perl)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        do {
            try process.run()
        } catch {
            watchdog.cancel()
            return false
        }
        // Drain stdout so a large `get` payload (artwork can be hundreds of KB)
        // can't deadlock the child against a full pipe buffer.
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        // `test` is authoritative via its exit code. `get` exits 0 when entitled
        // even if nothing is playing, so a clean exit is the signal we have.
        return process.terminationStatus == 0
    }

    // MARK: Adapter — streaming

    private func startAdapterStream(script: String, framework: String) {
        merged.removeAll()
        lineBuffer.removeAll()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: perlPath)
        // --micros gives integer microsecond duration/elapsed and an epoch
        // timestamp, which is exactly what the scrubber needs.
        process.arguments = [script, framework, "stream", "--micros"]

        let out = Pipe()
        process.standardOutput = out
        // We don't consume the adapter's stderr; discard it so it can never
        // block the child against a full pipe.
        process.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Hop to the main actor via the serial main queue (NOT an unstructured
            // Task, which has no ordering guarantee): the adapter splits large
            // updates — artwork is hundreds of KB — across several readability
            // callbacks, so chunks must reach `ingest`'s shared lineBuffer in the
            // exact order they arrived or the newline-delimited JSON gets scrambled.
            DispatchQueue.main.async { self?.ingest(chunk) }
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Same serial main-queue hop as ingest, so the relaunch (which resets
            // lineBuffer) is ordered after any chunks already queued from this pipe.
            DispatchQueue.main.async {
                guard let self, self.backend == .adapter else { return }
                NSLog("Canopy: adapter stream exited (status \(status)); restarting")
                // The stream is meant to run forever; relaunch unless we've stopped.
                // A 1s backoff keeps a crash-on-launch from busy-looping process
                // spawns. The `=== proc` guards ensure we only relaunch this stream
                // (not one a newer call already replaced).
                guard self.streamProcess === proc else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard self.backend == .adapter, self.streamProcess === proc else { return }
                    self.startAdapterStream(script: script, framework: framework)
                }
            }
        }

        do {
            try process.run()
            streamProcess = process
        } catch {
            NSLog("Canopy: failed to launch adapter stream: \(error); falling back")
            backend = .none
            resolveFallback()
        }
    }

    /// Accumulates stdout and parses complete newline-delimited JSON objects.
    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<idx)
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "data",
              let payload = obj["payload"] as? [String: Any] else { return }

        let isDiff = (obj["diff"] as? Bool) ?? false
        if isDiff {
            for (key, value) in payload {
                if value is NSNull { merged.removeValue(forKey: key) }
                else { merged[key] = value }
            }
        } else {
            merged = payload
        }
        onSnapshot?(snapshot(from: merged, payloadKeys: Set(payload.keys), isDiff: isDiff))
    }

    private func snapshot(from info: [String: Any], payloadKeys: Set<String>, isDiff: Bool) -> NowPlayingSnapshot {
        var s = NowPlayingSnapshot()
        s.title  = info["title"]  as? String ?? ""
        s.artist = info["artist"] as? String ?? ""
        s.album  = info["album"]  as? String ?? ""
        s.isPlaying = info["playing"] as? Bool ?? false

        if let micros = info["durationMicros"] as? Double { s.duration = micros / 1_000_000 }
        else if let secs = info["duration"] as? Double { s.duration = secs }

        if let micros = info["elapsedTimeMicros"] as? Double { s.elapsed = micros / 1_000_000 }
        else if let secs = info["elapsedTime"] as? Double { s.elapsed = secs }

        if let tsMicros = info["timestampEpochMicros"] as? Double {
            s.timestamp = Date(timeIntervalSince1970: tsMicros / 1_000_000)
        } else {
            s.timestamp = Date()
        }

        // Only treat artwork as "spoken about" when this update mentioned it, so a
        // metadata-only diff doesn't drop the current art.
        if !isDiff || payloadKeys.contains("artworkData") {
            s.carriedArtwork = true
            if let b64 = info["artworkData"] as? String {
                s.artworkData = Data(base64Encoded: b64)
            }
        }
        return s
    }

    /// Fire-and-forget adapter invocation for send/seek.
    private func runAdapter(_ trailing: [String]) {
        guard let scriptPath, let frameworkPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: perlPath)
        process.arguments = [scriptPath, frameworkPath] + trailing
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Direct MediaRemote backend (reuses MediaRemote.swift)

    private func startMediaRemote() {
        MediaRemote.shared.registerForNotifications()
        let nc = NotificationCenter.default
        nc.addObserver(forName: MediaRemote.infoDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emitMediaRemoteSnapshot() }
        }
        nc.addObserver(forName: MediaRemote.isPlayingDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emitMediaRemoteSnapshot() }
        }
        emitMediaRemoteSnapshot()
    }

    private func emitMediaRemoteSnapshot() {
        MediaRemote.shared.getNowPlayingInfo { [weak self] info in
            MediaRemote.shared.getIsPlaying { playing in
                Task { @MainActor in
                    guard let self else { return }
                    var s = NowPlayingSnapshot()
                    s.title  = info[MediaRemote.kTitle]  as? String ?? ""
                    s.artist = info[MediaRemote.kArtist] as? String ?? ""
                    s.album  = info[MediaRemote.kAlbum]  as? String ?? ""
                    s.duration = info[MediaRemote.kDuration] as? Double ?? 0
                    s.elapsed  = info[MediaRemote.kElapsed]  as? Double ?? 0
                    s.timestamp = Date()
                    if let rate = info[MediaRemote.kPlaybackRate] as? Double {
                        s.isPlaying = rate > 0
                    } else {
                        s.isPlaying = playing
                    }
                    s.carriedArtwork = true
                    s.artworkData = info[MediaRemote.kArtworkData] as? Data
                    self.onSnapshot?(s)
                }
            }
        }
    }

    // MARK: AppleScript backend

    private func startAppleScriptPolling() {
        pollAppleScript()
        appleScriptTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAppleScript() }
        }
    }

    private func pollAppleScript() {
        appleScript.snapshot { [weak self] snap in
            guard let snap else { return }
            Task { @MainActor in self?.onSnapshot?(snap) }
        }
    }
}
