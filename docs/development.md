# Development

Use Apple's Swift toolchain on macOS 13 or later. Install Xcode or Command Line Tools with `xcode-select --install` if `swiftc` is unavailable. The app uses Apple frameworks and has no package dependencies.

## Build and check

```sh
git clone https://github.com/DivyanshGolyan/claude-headroom.git
cd claude-headroom
bash test.sh
bash build.sh
open build/Headroom.app
```

`build.sh` creates a locally signed Apple Silicon app. Use a single running copy of Headroom; quit an installed copy before opening a development build.

`test.sh` checks forecast boundaries, burst detection, resets, counter corrections, missed observations, overlapping weekly outages, response decoding, clock formatting, VoiceOver wording, tabular digits, and stable widths across times and weekdays. Clock-domain tests advance continuous instants independently of calendar dates to check clock jumps, sleep, cooldowns, freshness, HTTP retry dates, server jitter, and stale cache restoration. Tests use synthetic quota data and do not access Keychain or the network. CI runs on an Apple Silicon macOS 15 runner. Other supported macOS versions have not been exercised in CI.

## Check dropdown alignment

To check dropdown alignment in a logged-in desktop session, run:

```sh
swiftc -swift-version 5 Sources/StatusMenu.swift Tests/StatusMenuTests.swift -o build/status-menu-tests
build/status-menu-tests
```

This briefly opens native menus at three button widths and checks their screen coordinates, minimum width, and highlight lifecycle. It requires a visible menu-bar item and runs separately from the headless test suite.

## Measure CPU work

```sh
bash benchmark.sh
```

The benchmark reports five batches of 1,000 operations for forecast calculation, gap-label layout, and response decoding. It uses synthetic data, consumes every result, and checks failures. Values are process CPU microseconds per operation after warm-up. It does not call Keychain or the network, measure app launch, or measure physical memory. Compare the same optimized builds on the same machine and alternate before and after runs. See [the efficiency measurements](performance.md) for the current comparison and its limits.

## Change the app

| File | Responsibility |
|---|---|
| `Sources/Forecast.swift` | Response decoding, quota history, rate calculation, labels, and accessible descriptions. |
| `Sources/UsageClient.swift` | Keychain credential reads and usage requests. |
| `Sources/App.swift` | App lifecycle, polling, freshness, menu, login item, and persistence. |
| `Sources/StatusStyle.swift` | Native typography and fixed widths per state. |
| `Sources/ClaudeMark.swift` | Cached template logo and outage warning icon. |
| `Sources/RefreshGate.swift` | Shared request spacing, single-flight state, and retry deadlines. |
| `Sources/RuntimeTimeline.swift` | Continuous observation timing, server calendar anchor, freshness, and stale restored snapshots. |
| `Sources/HTTPDate.swift` | HTTP date parsing and conversion of Retry-After to elapsed duration. |
| `Sources/ResponseTiming.swift` | Shared request budget and rejection of responses delayed by suspension. |
| `Sources/HistoryStore.swift` | Bounded cache reads and private atomic checkpoints. |

Keep elapsed deadlines typed as `ContinuousClock.Instant` and delays as `Duration`. Use `Date` for server quota timestamps, calendar anchoring, and display. `RuntimeTimeline` owns the bridge between these clocks. This separation follows [SwiftNIO's deadline design](https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/EventLoop.swift); deterministic clock advances follow the testing approach in [Point-Free Clocks](https://github.com/pointfreeco/swift-clocks). Headroom depends on neither library.

When changing quota rules, preserve immediate outage warnings and the 10% spare cutoff unless the intended behavior changes explicitly. Update the forecast reference and tests with the implementation. For UI changes, verify both appearance modes, narrow menu bars, and the existing four-point gap after the Claude logo. The states image in the README illustrates the native font and icons; it is not a screenshot of a live account.

## Package and release

```sh
bash package.sh
```

This builds the Apple Silicon app, creates `build/Headroom.dmg` and `build/Headroom.zip`, and writes `build/SHA256SUMS`. The disk image contains the app and an Applications shortcut. Verify an extracted app with `codesign --verify --strict`, and confirm `lipo -archs` reports only `arm64`.

For a release, update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Info.plist`. Commit, then tag the exact version:

```sh
git tag v1.1.0
git push origin main v1.1.0
```

The GitHub workflow tests the Apple Silicon build, checks that the tag matches the bundle version, packages the app, and publishes the release files and checksums. It uses GitHub's workflow token; no signing secrets are required. First-launch approval is expected because releases are ad-hoc signed and not Apple-notarized. Follow the README's per-app approval steps; packaging does not change system security settings.

After publishing, the Homebrew job downloads that exact release's ZIP and checksum file, verifies the archive, and updates `DivyanshGolyan/homebrew-headroom`. Its SSH deploy key can write only to that tap; the private key is stored in the app repository's `HEADROOM_TAP_DEPLOY_KEY` Actions secret. The updater rejects downgrades and changed checksums for an existing version. Identical retries make no commit.

If the release exists but tap publication fails, retry the failed Homebrew job or run the same workflow independently:

```sh
gh workflow run homebrew.yml --field tag=v1.2.0
```

This does not rebuild the app or recreate the release. `Tests/test_homebrew_release.py` checks archive verification, version ordering, and retry behavior without network access.
