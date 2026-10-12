# Efficiency measurements

The optimization reduces repeated formatting work. It does not establish a large reduction in whole-app CPU or memory.

## CPU comparison

Measured on an Apple M1 Pro with macOS 15.7.7 and Swift 6.2.4, using `-O -swift-version 5` for both builds. The baseline is commit `0bb7828`. Five before-and-after process pairs alternated on the same machine. Each process ran five warmed batches of 1,000 operations per path, for 25,000 operations per side. Every result contributed to a checksum. All fixture checks passed with zero errors.

Values are process CPU microseconds per operation. The table reports the median and the full batch range.

| Path | Before | After | Before range | After range |
|---|---:|---:|---|---|
| Forecast, 61 samples | 10.42 | 10.36 | 10.16 to 10.84 | 10.11 to 10.63 |
| Gap label and width | 99.33 | 19.36 | 96.26 to 107.23 | 18.33 to 19.88 |
| Decode two quota windows | 444.47 | 105.47 | 427.24 to 467.63 | 100.54 to 110.03 |

Forecast calculation has no measurable change. The reduced paths reuse date formatters and measured text widths. A separate baseline sample showed repeated ISO formatter initialization and ICU date-formatter setup in the decoding path. The benchmark does not include network requests, Keychain helpers, disk writes, actual menu-bar property mutations, or launch costs. A reduction in these isolated costs is not the same as a whole-app speedup.

The host had substantial competing load and memory compression. Process CPU measurements reduce the effect of waiting on other apps, but do not remove all interference. These results apply to warmed synthetic fixtures, not every account or machine. Run `bash benchmark.sh` to repeat the current-source measurement.

## Memory and resource bounds

The original running app had roughly 21 MB physical footprint, with a recorded peak of 23.7 MB. That was a short observation of an older process, not a leak test. No controlled before-and-after footprint reduction is claimed. Small caches can increase retained memory while reducing allocation churn.

The app now retains two logo images, two ISO date parsers, one HTTP date parser, four clock formatter configurations for one environment, and at most 16 text measurements. In-memory history retains at most 256 consecutive observations; disk checkpoints contain only the latest snapshot. A cached snapshot does not supply rates after restarting the app. Restored files larger than 256 KiB are rejected before decoding. Timer, wake, and manual requests share a 15-second minimum spacing and one in-flight request.

Scheduled updates remain approximately once a minute. The app still reads fresh credentials through `/usr/bin/security` on each actual fetch. A noninteractive native Keychain experiment was denied on the existing item, so the app keeps the compatible reader instead of introducing another permission prompt. No credential cache or forecast arithmetic change is part of the optimization.
