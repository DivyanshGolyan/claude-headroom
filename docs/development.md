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

`build.sh` creates a locally signed universal app for Apple Silicon and Intel. Set `ARCHS=arm64` or `ARCHS=x86_64` to build only one architecture. Use a single running copy of Headroom; quit an installed copy before opening a development build.

`test.sh` checks forecast boundaries, burst detection, resets, counter corrections, missed observations, overlapping weekly outages, response decoding, clock formatting, VoiceOver wording, tabular digits, and stable widths across times and weekdays. Tests use synthetic quota data and do not access Keychain or the network. CI runs on Apple Silicon and Intel macOS 15 runners. Other supported macOS versions have not been exercised in CI.

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
| `Sources/HistoryStore.swift` | Bounded cache reads and private atomic checkpoints. |

When changing quota rules, preserve immediate outage warnings and the 10% spare cutoff unless the intended behavior changes explicitly. Update the forecast reference and tests with the implementation. For UI changes, verify both appearance modes, narrow menu bars, and the existing four-point gap after the Claude logo. The states image in the README illustrates the native font and icons; it is not a screenshot of a live account.

## Package and release

```sh
bash package.sh
```

This builds the universal app, creates `build/Headroom.dmg` and `build/Headroom.zip`, and writes `build/SHA256SUMS`. The disk image contains the app and an Applications shortcut. Verify an extracted app with `codesign --verify --strict`, and confirm its architectures with `lipo -archs`.

For a release, update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Info.plist`. Commit, then tag the exact version:

```sh
git tag v1.1.0
git push origin main v1.1.0
```

The GitHub workflow tests both architectures, checks that the tag matches the bundle version, packages the universal app, and publishes the release files and checksums. It uses GitHub's workflow token; no signing secrets are required. First-launch approval is expected because releases are ad-hoc signed and not Apple-notarized. Follow the README's per-app approval steps; packaging does not change system security settings.
