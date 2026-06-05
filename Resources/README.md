# Bundled resources — MediaRemote adapter

Canopy reads and controls system-wide now-playing media through
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD-3-Clause). This works on **all macOS versions, including 15.4+**, where
direct MediaRemote access is otherwise restricted: the Apple-signed
`/usr/bin/perl` is entitled to use the framework, and the Perl script
dynamically loads a small helper framework that streams now-playing JSON to
stdout.

## What's here

| File | Tracked in git? | How it's used |
|------|-----------------|---------------|
| `mediaremote-adapter.pl` | ✅ yes (text, reviewable) | Run via `/usr/bin/perl`; emits/streams now-playing JSON and forwards commands. |
| `MediaRemoteAdapter.framework` | ❌ no (built artifact) | Loaded **by the Perl script**, not by Canopy. Bundled into `Contents/Resources` and passed to perl by path. **Never linked or embedded.** |
| `MediaRemoteAdapterTestClient` | ❌ no (built artifact) | Optional helper for the `test` health-check command. |

The compiled framework + test client are produced by
[`../Scripts/fetch-adapter.sh`](../Scripts/fetch-adapter.sh) and are
git-ignored. They are a Mach-O bundle that must be built on macOS (CMake), which
is why they are not committed.

## Build them

```sh
./Scripts/fetch-adapter.sh        # needs Xcode CLT + cmake; populates this dir
xcodegen generate
xcodebuild -scheme Canopy build
```

If the framework is absent at runtime, `MediaController` detects this (the
`test`/`get` health check fails) and falls back to AppleScript control of
Music / Spotify, so the app still builds and runs.

## Why bundled, not linked

The framework is **only ever referenced by path** and loaded inside the
`perl` process via `DynaLoader`. Canopy itself never links against it or loads
it into its own address space — that's the whole point of the adapter design,
and it keeps Canopy free of the private MediaRemote symbols.
