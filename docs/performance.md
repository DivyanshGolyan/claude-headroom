# Efficiency measurements

The optimization reduces repeated formatting work. It does not establish a large reduction in whole-app CPU or memory.

## CPU comparison

Measured on an Apple M1 Pro with macOS 15.7.7 and Swift 6.2.4, using `-O -swift-version 5` for both builds. The baseline is commit `0bb7828`; the optimized code was committed as `fe0af52`, before the clock-safety and initial-estimate changes. Five before-and-after process pairs alternated on the same machine. Each process ran five warmed batches of 1,000 operations per path, for 25,000 operations per side. Every result contributed to a checksum. All fixture checks passed with zero errors.

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

The app now retains two logo images, two ISO date parsers, one HTTP date parser, four clock formatter configurations for one environment, and at most 16 text measurements. In-memory history retains at most 256 consecutive observations; disk checkpoints contain only the latest snapshot. A cached snapshot does not supply rates after restarting the app. Restored files larger than 256 KiB are rejected before decoding. Timer, wake, and manual requests share one in-flight request and respect server cooldowns.

Usage checks run every five minutes. The display uses a one-shot timer for the next forecast, freshness, or calendar transition instead of updating every minute. Retry timers target their deadlines directly. The app still reads fresh credentials through `/usr/bin/security` on each actual fetch. A noninteractive native Keychain experiment was denied on the existing item, so the app keeps the compatible reader instead of introducing another permission prompt. No credential cache was introduced. Later changes allow initial window-average forecasts before a recent rate is available; the benchmark's 61-sample forecast fixture exercises the established recent-rate calculation.

Forecast calculation supplies the next exhaustion or reset boundary, including windows hidden by overlapping outages. The timeline adds dimming, stale-tooltip resets, and midnight in both the wall and server-anchored calendars. Calendar checks can cause up to two daily display wakeups even when the text stays unchanged. Menu close, fetches, wake, and clock changes also update the display. The display timer allows two seconds of tolerance. Tests cover strict freshness boundaries, overlapping outages, clock jumps, and daylight-saving transitions. This removes unconditional minute callbacks; it does not establish a whole-app CPU or memory reduction.

## Repeatable whole-app measurements

Measure an **already running release build** by PID. The script only reads process counters; it does not launch Headroom, access credentials, trigger requests, or stop the target. Headroom continues its normal background activity during observation.

```sh
python3 scripts/measure-app.py --pid 12345 --duration 600 --interval 5 \
  --build-label 'revision, release, baseline, idle-1' > /tmp/headroom-baseline-idle-1.json
```

Use the PID of the intended build from Activity Monitor. Build labels are supplied by the operator; the output also records the loaded executable's UUID and process start identity. A changed identity, exited process, or unreadable counter makes the run fail with a nonzero status and an error on stderr. Do not interpret the empty output file from a failed run as a result. No process arguments, environment, hostname, account data, or executable paths are collected.

The JSON records cumulative user/system CPU deltas, CPU percentage where one fully occupied core is 100%, sampled physical footprint in bytes, Darwin package-idle and interrupt wakeup deltas, individual samples, actual monotonic elapsed time, OS/architecture/core count, and host load at both ends. Footprint maxima are sampled maxima, not lifetime peaks. The wakeup counters are not a count of every timer callback; a zero means the kernel counter did not advance. Unavailable child CPU and timer callback counts are `null`, never reported as zero. These readings cover the app process; they exclude `/usr/bin/security`, other children, and work performed by system services. Use a separate Instruments capture when investigating those costs.

For a comparison, state the expected outcome first (for example, lower idle CPU and fewer wakeups with unchanged forecast behavior). Use identical release flags, account state, settings, warm-up, and scenario duration. Run at least five observations per build, alternating baseline and candidate, and report the median and full range. Keep the raw JSON files. Compare idle, fetch completion, failed fetch, sleep/wake, and repeated menu opening as separate scenarios. Record actions, successful/failed requests, and observed display behavior alongside each run: this script does not observe those outcomes. Include enough time to cross the relevant display and polling deadlines; a short idle run cannot establish fetch cost or leak behavior. Sleep/wake is its own scenario because sleep changes the time available to execute work.

Report no measurable difference when the gap is smaller than run-to-run variation. This harness establishes a repeatable observation method; its own smoke tests do not establish a Headroom performance improvement.

Verify the counter calculations, replacement detection, and macOS process integration with:

```sh
python3 -m unittest discover -s Tests -p test_measure_app.py
```
