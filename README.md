# 🌿 Canopy

[![Build](https://github.com/6gx42o/Canopy/actions/workflows/build.yml/badge.svg)](https://github.com/6gx42o/Canopy/actions/workflows/build.yml)

A refined, productivity-focused **Dynamic Island experience for macOS** — a native SwiftUI app that wraps your Mac's notch with media controls, time-synced lyrics, a Liquid Glass desktop widget, a matching screen saver, a file-drop shelf, and notification mirroring.

> Inspired by [getcanopy.pro](https://getcanopy.pro/). Built from scratch in Swift.

## Features

- **Notch media player** — a Liquid Glass slab that hugs the notch and expands on hover into a full player: artwork, title/artist, animated EQ bars, a **scrubbable** progress bar, and play / prev / next. On **macOS 26** it uses Apple's native **Liquid Glass** material (real refraction, specular edges, depth, interactive response); older systems get a refined dark frosted-glass fallback. Reads & controls whatever is playing system-wide via the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (works on macOS 15.4+, where direct `MediaRemote` access is otherwise blocked), with automatic fallback to the in-process `MediaRemote` bridge and then to AppleScript control of Music / Spotify.
- **Time-synced lyrics** — fetched from [LRCLIB](https://lrclib.net) (free, no API key), parsed from LRC, and tracked against playback. Shown in the notch and the widget with **Apple-Music-style color gradients** sampled from the album art. **Tap a line to seek.**
- **Liquid Glass widget** — a frosted-glass **desktop** widget (behind-window blur + album-art gradient) with **4 presets**: Lockscreen-style (iOS clock + now-playing card), Now Playing (art-forward), Lyrics (scrolling synced), and Minimal Clock. Drag it anywhere — it remembers where you put it — and tune its **opacity**. The clock follows your system 12/24-hour and locale settings.
- **Screen saver** — the same now-playing card as a macOS screen saver, the closest thing macOS allows to a lock-screen widget (third-party apps can't draw on the real lock screen). See [Screen saver](#screen-saver).
- **Notch banners** — now-playing changes and **mirrored system notifications** slide down from the notch. Mirroring tails the Notification Center database (requires Full Disk Access; degrades gracefully).
- **File-drop shelf** — drop files onto the notch to stash them, then drag them back out, reveal in Finder, or clear.
- **Menu-bar app** — no Dock icon. Toggle the notch island or the widget, switch presets, set widget opacity, enable Launch at Login, and grant access from the leaf menu. Turn the island off to run Canopy as a menu-bar + desktop-widget app only (handy on external displays).
- **Accessible & efficient** — VoiceOver labels on the transport controls and scrubber; honors the system **Reduce Motion** and **Reduce Transparency** settings; idle CPU stays low (the notch/widget stop re-rendering when nothing is playing, and the screen-saver feed only writes a new frame when the card actually changes).

## Requirements

- **Runs on** macOS 14+ (Liquid Glass on macOS 26; refined fallback below it)
- **Builds with Xcode 26** — the Liquid Glass APIs (`glassEffect`) need the macOS 26 SDK at compile time, even though the app back-deploys to macOS 14. CI builds on a `macos-26` runner.

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

## Screen saver

macOS has **no third-party lock-screen widget API** — the lock screen is drawn by
a separate secure process and your app's windows are hidden while locked. The
closest supported surface is a **screen saver**, so Canopy ships one
(`CanopyScreenSaver.saver`).

It works as a producer/consumer pair, because the screen-saver sandbox can't read
media or spawn helpers:

- The **app** renders the selected widget preset to a PNG ~once a second into a
  shared **App Group** container (`LockscreenFeed` → `CanopyShared`).
- The **saver** is a pure consumer that draws the latest frame
  (`CanopyScreenSaverView`).

### Install

```sh
./Scripts/install-screensaver.sh     # builds + copies CanopyScreenSaver.saver
```

Then enable **“Show on Screen Saver”** from the Canopy menu, and pick **Canopy**
in System Settings → Screen Saver.

### Signing requirement & caveats

- The app and the saver **must be signed with the same Apple Team ID** and share
  the App Group `group.pro.getcanopy.shared` — that's the only directory a
  sandboxed saver can read. Set `DEVELOPMENT_TEAM` (env var for the script, or in
  the Xcode project). **Ad-hoc/unsigned builds** can't share the container, so the
  saver shows a placeholder.
- This reliably shows while the Mac is **idle / screensaving**. Once it is *fully
  locked*, the saver runs in a restricted context that may not reach your
  session's frames — that's a macOS limitation, not a Canopy bug.

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
| `LockscreenFeed.swift` / `CanopyShared.swift` | Renders widget frames to the shared App Group container for the saver |
| `Sources/CanopyScreenSaver/` / `Scripts/install-screensaver.sh` | The `.saver` bundle (frame consumer) + installer |
| `NotificationMirror.swift` | Notification Center DB tailing |
| `SettingsStore.swift` | Persisted settings + Launch at Login |
| `AppIcon.swift` | Programmatic app icon |

## Notes

This is an independent, educational reimplementation — not affiliated with Canopy. It reaches now-playing media through the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), which is invoked via the Apple-signed `/usr/bin/perl` and never linked into the app, so it is intended for personal use, not the Mac App Store.

🤖 Built with [Claude Code](https://claude.com/claude-code)
