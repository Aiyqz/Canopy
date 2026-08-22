// Banner.swift —— 灵动岛横幅数据模型（切歌 / 系统通知镜像时弹出）。
import AppKit

/// A transient banner shown in the notch — either a "now playing" change or a
/// mirrored system notification.
struct NotchBanner: Identifiable, Equatable {
    enum Kind { case nowPlaying, system }

    let id = UUID()
    var title: String
    var subtitle: String?
    var body: String?
    var icon: NSImage?
    var kind: Kind = .system

    static func == (lhs: NotchBanner, rhs: NotchBanner) -> Bool { lhs.id == rhs.id }
}
