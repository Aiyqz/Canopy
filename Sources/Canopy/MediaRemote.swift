import Foundation

/// Thin wrapper around the private MediaRemote.framework.
///
/// This is the same mechanism that real notch apps (NotchNook, BoringNotch, …)
/// use to read and control whatever is playing system-wide. The symbols are
/// resolved dynamically so the app keeps running even if Apple changes them.
final class MediaRemote {
    static let shared = MediaRemote()

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    // MARK: NowPlaying info keys
    static let kTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    static let kArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    static let kAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let kArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let kDuration = "kMRMediaRemoteNowPlayingInfoDuration"
    static let kElapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let kPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    // MARK: Notification names
    static let infoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let isPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) ([String: Any]) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommandFn = @convention(c) (Int, [String: Any]?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private let getInfoFn: GetInfoFn?
    private let getIsPlayingFn: GetIsPlayingFn?
    private let registerFn: RegisterFn?
    private let sendCommandFn: SendCommandFn?
    private let setElapsedFn: SetElapsedFn?

    let isAvailable: Bool

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        getInfoFn = sym("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
        getIsPlayingFn = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self)
        registerFn = sym("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        sendCommandFn = sym("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        setElapsedFn = sym("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self)

        isAvailable = getInfoFn != nil && sendCommandFn != nil
    }

    func registerForNotifications() {
        registerFn?(.main)
    }

    func getNowPlayingInfo(_ completion: @escaping ([String: Any]) -> Void) {
        guard let getInfoFn else { completion([:]); return }
        getInfoFn(.main) { info in completion(info) }
    }

    func getIsPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let getIsPlayingFn else { completion(false); return }
        getIsPlayingFn(.main) { playing in completion(playing) }
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommandFn?(command.rawValue, nil) ?? false
    }

    /// Seek the currently playing app to an absolute time (seconds).
    func setElapsed(_ seconds: Double) {
        setElapsedFn?(seconds)
    }
}
