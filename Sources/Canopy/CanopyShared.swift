import Foundation
import os

/// Tiny IPC surface shared by the Canopy app (the writer) and the
/// CanopyScreenSaver bundle (the reader). The screen-saver sandbox can't read
/// media or arbitrary files, so the app renders the now-playing card to a PNG
/// and drops it — plus a small JSON status — into a shared directory that the
/// saver then displays.
///
/// This file is compiled into BOTH targets (see project.yml).
enum CanopyShared {
    /// App Group used when the app and the saver are signed with the same Team
    /// ID. This is the only directory a sandboxed screen saver can read
    /// reliably. For ad-hoc/unsigned dev builds the group container is nil and we
    /// fall back to Application Support, which the saver sandbox will likely
    /// block — so the saver shows its placeholder. See README "Screen saver".
    static let appGroupID = "group.pro.getcanopy.shared"

    static var directory: URL {
        let fm = FileManager.default
        let base: URL
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            base = group
        } else {
            base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory).appendingPathComponent("Canopy", isDirectory: true)
        }
        let dir = base.appendingPathComponent("Screensaver", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var frameURL: URL { directory.appendingPathComponent("frame.png") }
    static var statusURL: URL { directory.appendingPathComponent("status.json") }

    /// True when the App Group container resolves — i.e. the saver can read what
    /// the app writes. False means we're on the Application Support fallback,
    /// which the sandboxed saver almost certainly can't read.
    static var isUsingAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    private static let log = Logger(subsystem: "pro.getcanopy", category: "screensaver")
    private static var didLog = false

    /// Logs the resolved directory once per process. Visible in Console.app —
    /// filter by "Canopy" — from both the app and the legacyScreenSaver host, so
    /// you can confirm whether the App Group is shared correctly.
    static func logResolutionOnce(role: String) {
        guard !didLog else { return }
        didLog = true
        if isUsingAppGroup {
            log.notice("[\(role, privacy: .public)] shared dir = \(directory.path, privacy: .public) (App Group OK)")
        } else {
            log.error("[\(role, privacy: .public)] App Group '\(appGroupID, privacy: .public)' did NOT resolve — using fallback \(directory.path, privacy: .public). The sandboxed screen saver can't read this; sign both targets with the same Team ID.")
        }
    }
}

/// Written next to the frame so the saver can pick a sensible background colour
/// and notice stale frames (app quit / nothing playing).
struct CanopyShareStatus: Codable {
    var updated: Date
    var isPlaying: Bool
    var hasMedia: Bool
    var backgroundHex: String   // "#RRGGBB", from the album-art palette
}
