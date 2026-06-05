# 🌿 Canopy

A refined, productivity-focused **Dynamic Island experience for macOS** — a native SwiftUI app that wraps your Mac's notch with media controls, time-synced lyrics, a Liquid Glass lockscreen widget, a file-drop shelf, and notification mirroring.

> Inspired by [getcanopy.pro](https://getcanopy.pro/). Built from scratch in Swift.

## Features

- **Notch media player** — a black slab that hugs the notch and expands on hover into a full player: artwork, title/artist, animated EQ bars, a **scrubbable** progress bar, and play / prev / next. Reads & controls whatever is playing system-wide via the private `MediaRemote` framework.
- **Time-synced lyrics** — fetched from [LRCLIB](https://lrclib.net) (free, no API key), parsed from LRC, and tracked against playback. Shown in the notch and the widget with **Apple-Music-style color gradients** sampled from the album art. **Tap a line to seek.**
- **Liquid Glass lockscreen widget** — a frosted-glass desktop widget (behind-window blur + album-art gradient) with **4 presets**: Lockscreen (iOS-style clock + now-playing card), Now Playing (art-forward), Lyrics (scrolling synced), and Minimal Clock.
- **Notch banners** — now-playing changes and **mirrored system notifications** slide down from the notch. Mirroring tails the Notification Center database (requires Full Disk Access; degrades gracefully).
- **File-drop shelf** — drop files onto the notch to stash them, then drag them back out, reveal in Finder, or clear.
- **Menu-bar app** — no Dock icon. Toggle the widget, switch presets, enable Launch at Login, and grant access from the leaf menu.

## Requirements

- macOS 14+ (developed on macOS 26 / Apple Silicon)
- Swift 6.2 / Xcode 26

## Build & run

```sh
./build.sh release      # compiles + assembles an ad-hoc-signed Canopy.app (with icon)
open Canopy.app
```

Or during development:

```sh
swift build
swift run Canopy
```

### Verification render mode

The app can render its own UI to PNG offscreen (no screen-recording permission needed):

```sh
swift run Canopy --snapshot /tmp     # writes notch + widget preset PNGs
swift run Canopy --icon /tmp/icon.png
```

## Permissions

- **Media control / now-playing** — works out of the box via `MediaRemote`.
- **Notification mirroring** — needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access → add Canopy). The leaf menu shows live status and a shortcut to the settings pane. Now-playing banners work without it.

## Project layout

| Path | Purpose |
|------|---------|
| `Sources/Canopy/main.swift` | Entry point + `--snapshot` / `--icon` modes |
| `MediaRemote.swift` | Private MediaRemote.framework bridge |
| `NowPlayingModel.swift` | Observable state: playback, lyrics, palette, shelf, banners |
| `LyricsService.swift` | LRCLIB fetch + LRC parsing |
| `ColorExtractor.swift` | Album-art → gradient palette |
| `NotchController.swift` / `Views/NotchView.swift` | The notch window + collapsed / banner / expanded UI |
| `WidgetController.swift` / `Views/WidgetView.swift` / `Views/WidgetContent.swift` | Liquid Glass desktop widget + presets |
| `NotificationMirror.swift` | Notification Center DB tailing |
| `SettingsStore.swift` | Persisted settings + Launch at Login |
| `AppIcon.swift` | Programmatic app icon |

## Notes

This is an independent, educational reimplementation — not affiliated with Canopy. It uses Apple's private `MediaRemote` framework (the same approach as other notch apps), so it is intended for personal use, not the Mac App Store.

🤖 Built with [Claude Code](https://claude.com/claude-code)
