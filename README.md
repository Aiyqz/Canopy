# 🌿 Canopy

A refined, productivity-focused **Dynamic Island experience for macOS** — a native SwiftUI app that wraps your Mac's notch with media controls, time-synced lyrics, a Liquid Glass lockscreen widget, a file-drop shelf, and notification mirroring.

> Inspired by [getcanopy.pro](https://getcanopy.pro/). Built from scratch in Swift.

## Features

- **Notch media player** — a black slab that hugs the notch and expands on hover into a full player: artwork, title/artist, animated EQ bars, a **scrubbable** progress bar, and play / prev / next. Reads & controls whatever is playing system-wide via the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (works on macOS 15.4+, where direct `MediaRemote` access is otherwise blocked), with automatic fallback to the in-process `MediaRemote` bridge and then to AppleScript control of Music / Spotify.
- **Time-synced lyrics** — fetched from [LRCLIB](https://lrclib.net) (free, no API key), parsed from LRC, and tracked against playback. Shown in the notch and the widget with **Apple-Music-style color gradients** sampled from the album art. **Tap a line to seek.**
- **Liquid Glass lockscreen widget** — a frosted-glass desktop widget (behind-window blur + album-art gradient) with **4 presets**: Lockscreen (iOS-style clock + now-playing card), Now Playing (art-forward), Lyrics (scrolling synced), and Minimal Clock.
- **Notch banners** — now-playing changes and **mirrored system notifications** slide down from the notch. Mirroring tails the Notification Center database (requires Full Disk Access; degrades gracefully).
- **File-drop shelf** — drop files onto the notch to stash them, then drag them back out, reveal in Finder, or clear.
- **Menu-bar app** — no Dock icon. Toggle the widget, switch presets, enable Launch at Login, and grant access from the leaf menu.

## Requirements

- macOS 14+ (developed on macOS 26 / Apple Silicon)
- Swift 6.2 / Xcode 26

## Build & run

First, build the bundled MediaRemote adapter once (needs Xcode CLT + cmake):

```sh
./Scripts/fetch-adapter.sh    # populates Resources/ with the framework + test client
```

### Xcode / XcodeGen (primary)

The `.xcodeproj` is generated from [`project.yml`](project.yml):

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme Canopy build
```

### Swift Package Manager (dev)

```sh
./build.sh release      # compiles + assembles an ad-hoc-signed Canopy.app (with icon + adapter)
open Canopy.app
```

Or during development:

```sh
swift build
swift run Canopy
```

> If you skip `fetch-adapter.sh`, the app still builds and runs — `MediaController`
> falls back to AppleScript control of Music / Spotify (which triggers an
> Automation permission prompt the first time).

### Verification render mode

The app can render its own UI to PNG offscreen (no screen-recording permission needed):

```sh
swift run Canopy --snapshot /tmp     # writes notch + widget preset PNGs
swift run Canopy --icon /tmp/icon.png
```

## Permissions

- **Media control / now-playing** — works out of the box via the bundled adapter. If the adapter is unavailable and Canopy falls back to AppleScript, macOS shows a one-time **Automation** prompt to allow controlling Music / Spotify.
- **Notification mirroring** — needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access → add Canopy). The leaf menu shows live status and a shortcut to the settings pane. Now-playing banners work without it.

## Project layout

| Path | Purpose |
|------|---------|
| `project.yml` / `Scripts/fetch-adapter.sh` | XcodeGen spec + adapter build script |
| `Resources/mediaremote-adapter.pl` | Bundled adapter script (BSD-3); loaded by `/usr/bin/perl` |
| `Sources/Canopy/main.swift` | Entry point + `--snapshot` / `--icon` modes |
| `MediaController.swift` | Resolves & drives the media backend (adapter → MediaRemote → AppleScript) |
| `AppleScriptMedia.swift` | Music / Spotify control via `osascript` (fallback backend) |
| `MediaRemote.swift` | Private MediaRemote.framework bridge (secondary fallback) |
| `NowPlayingModel.swift` | Observable state: playback, lyrics, palette, shelf, banners |
| `LyricsService.swift` | LRCLIB fetch + LRC parsing |
| `ColorExtractor.swift` | Album-art → gradient palette |
| `NotchController.swift` / `Views/NotchView.swift` | The notch window + collapsed / banner / expanded UI |
| `WidgetController.swift` / `Views/WidgetView.swift` / `Views/WidgetContent.swift` | Liquid Glass desktop widget + presets |
| `NotificationMirror.swift` | Notification Center DB tailing |
| `SettingsStore.swift` | Persisted settings + Launch at Login |
| `AppIcon.swift` | Programmatic app icon |

## Notes

This is an independent, educational reimplementation — not affiliated with Canopy. It reaches now-playing media through the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), which is invoked via the Apple-signed `/usr/bin/perl` and never linked into the app, so it is intended for personal use, not the Mac App Store.

🤖 Built with [Claude Code](https://claude.com/claude-code)
