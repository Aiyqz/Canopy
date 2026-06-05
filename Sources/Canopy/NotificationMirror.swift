import AppKit
import SQLite3

/// Mirrors macOS system notifications into the notch by tailing the Notification
/// Center SQLite database. This is the same approach notch apps use; it requires
/// **Full Disk Access** (the DB lives under a TCC-protected path). When access
/// isn't granted, `status` reflects that and no banners are produced — the
/// now-playing banners still work regardless.
@MainActor
final class NotificationMirror {
    enum Status: Equatable {
        case inactive
        case active
        case noAccess
        case unavailable

        var menuText: String {
            switch self {
            case .inactive:    return "Notifications: starting…"
            case .active:      return "Notifications: mirroring active"
            case .noAccess:    return "Notifications: needs Full Disk Access"
            case .unavailable: return "Notifications: database not found"
            }
        }
    }

    private(set) var status: Status = .inactive
    var onBanner: ((NotchBanner) -> Void)?
    var onStatusChange: (() -> Void)?

    private var db: OpaquePointer?
    private var lastRecId: Int64 = 0
    private var timer: Timer?
    private var ownBundleID = Bundle.main.bundleIdentifier ?? ""

    func start() {
        guard let path = Self.databasePath() else {
            setStatus(.unavailable)
            return
        }
        // Open read-only. Fails (or yields an empty result) without Full Disk Access.
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            setStatus(.noAccess)
            db = nil
            return
        }
        // A probe query confirms we can actually read the protected file.
        guard probeReadable() else {
            setStatus(.noAccess)
            sqlite3_close(db); db = nil
            return
        }
        setStatus(.active)
        lastRecId = currentMaxRecId()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if db != nil { sqlite3_close(db); db = nil }
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        onStatusChange?()
    }

    // MARK: DB plumbing

    private static func databasePath() -> String? {
        // $(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        process.arguments = ["DARWIN_USER_DIR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let dir = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty
        else { return nil }
        let path = (dir as NSString).appendingPathComponent("com.apple.notificationcenter/db2/db")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func probeReadable() -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM record", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func currentMaxRecId() -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT max(rec_id) FROM record", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private func poll() {
        guard db != nil else { return }
        let sql = """
        SELECT record.rec_id, record.data, app.identifier
        FROM record LEFT JOIN app ON record.app_id = app.app_id
        WHERE record.rec_id > ?
        ORDER BY record.rec_id ASC
        LIMIT 8
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, lastRecId)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = sqlite3_column_int64(stmt, 0)
            lastRecId = max(lastRecId, recId)

            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 1))
            let data = Data(bytes: blob, count: length)

            var bundleID = ""
            if let cStr = sqlite3_column_text(stmt, 2) {
                bundleID = String(cString: cStr)
            }
            if bundleID == ownBundleID { continue }

            if let banner = Self.banner(from: data, bundleID: bundleID) {
                onBanner?(banner)
            }
        }
    }

    // MARK: Payload parsing

    private static func banner(from data: Data, bundleID: String) -> NotchBanner? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return nil }

        // The notification request lives under "req".
        let req = (root["req"] as? [String: Any]) ?? root
        let title = (req["titl"] as? String) ?? ""
        let subtitle = req["subt"] as? String
        let body = req["body"] as? String

        let appName = displayName(for: bundleID)
        let primary = title.isEmpty ? appName : title
        guard !primary.isEmpty || !(body ?? "").isEmpty else { return nil }

        var secondary = body
        if let sub = subtitle, !sub.isEmpty {
            secondary = body.map { "\(sub) — \($0)" } ?? sub
        }

        return NotchBanner(
            title: primary,
            subtitle: title.isEmpty ? nil : appName,
            body: secondary,
            icon: appIcon(for: bundleID),
            kind: .system
        )
    }

    private static func displayName(for bundleID: String) -> String {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private static func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
