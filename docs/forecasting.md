# Forecasting

Headroom samples account quota approximately once a minute from `https://api.anthropic.com/api/oauth/usage`. This includes usage reflected by the server from other sessions and devices. It reads the Claude Code login stored in macOS Keychain through `/usr/bin/security`.

## Rates and thresholds

For each tracked quota window, calculate two rates from changes in its cumulative usage percentage:

- Short rate: the last 10 minutes.
- Long rate: the remaining time until reset, clamped to a lookback of 15–60 minutes.

Use the faster rate for both exhaustion and spare forecasts. This conservatively catches bursts, even when earlier observations include idle time. All observed time counts, including idle time. Once live observations span at least one minute, use their measured rate and refine it as history grows. When there is less history than the lookback, use the available observations. Early estimates are noisier, especially when counters change in whole percentage points. A minute with no reported increase counts as zero observed consumption, even though rounding or delayed reporting may hide some usage.

Before a measured rate is available, estimate average consumption since the quota window began. Infer the start as reset minus five hours for session quota, or seven days for decoded weekly limits. These durations follow [Claude's documented session and weekly limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work); the internal endpoint does not provide a start timestamp. Require at least one elapsed minute and an inferred start within the window. This initial estimate assumes uniform consumption since that start and may miss recent bursts. It never adds invented observations to history. A measured rate, including zero, replaces it as soon as available.

```text
remaining = 100 − latest usage percentage
exhaustion = latest observation time + remaining / rate
spare = remaining − rate × time from latest observation to reset
```

Any predicted shortfall immediately produces an outage warning. There is no product tolerance or delayed warning. Projected spare of at least 10% produces a spare label; anything from 0% to under 10% is On track. Floating-point roundoff is removed at one-billionth of a percentage point so exact boundaries stay exact.

Estimated exhaustion times round down to five minutes. Spare rounds down to five percentage points. Displayed reset times round to the nearest minute so sub-second server jitter across a minute boundary does not flicker. Calculations retain the precise reset timestamp. Five-hour labels use the system's 12/24-hour convention with the meridiem removed. Weekly labels retain it in 12-hour locales and include the weekday when needed.

## Continuity and coverage

Keep observations through sleep and failed requests while the app remains running. Cumulative usage captures consumption between observations; interpolate an anchor at the lookback boundary. Across a long interruption this assumes uniform consumption over the missing interval, so the actual timing of a burst is unknown. A reset or a decreasing counter starts a fresh rate history for that quota window. Rates from an earlier window are not used as priors.

Five-hour quota drives spare estimates. Active, unscoped weekly limits and active Opus weekly limits also participate in outage detection. Other model-specific limits, such as Sonnet or Fable, are excluded. This policy suits Opus-heavy work; it is not a complete forecast for every model. Weekly rates use their own observations and the same initial-average fallback. A counter already at 100% warns immediately. Overlapping outages merge into the earliest continuous outage; the displayed end is when all overlapping limits have reset.

A null five-hour window, or zero utilization with no reset time, is treated as Ready. An absent required field, malformed reset, or invalid percentage is an error. The no-active-window interpretation is defensive handling of that response shape, not a guarantee about every server response.

## Clock changes

Request spacing, retries, rate-limit cooldowns, and data age use Swift's `ContinuousClock`. It measures elapsed time through sleep and ignores changes to the system clock. Quota reset timestamps remain absolute calendar dates.

Live observations share one calendar anchor, preferably the response's HTTP Date header. Each observation advances that anchor by continuous elapsed time. This keeps consumption rates and history retention stable when the local clock changes. If the header is absent, the first response's local date supplies a best-effort anchor. The first subsequent server date, or a server date differing from the projected anchor by more than 30 seconds, starts fresh observations. Smaller server jitter leaves the anchor unchanged. The 30-second tolerance is a drift policy, not a bound guaranteed by the network timeout.

A numeric Retry-After becomes an elapsed duration directly. An HTTP-date Retry-After is compared with the response's server date, falling back to the local date captured at receipt. Later clock changes cannot shorten or extend that cooldown. Without a server date, an initially incorrect local clock can still affect this conversion and the quota reset horizon.

## Freshness and storage

Requests time out after 25 seconds overall. Headroom also rejects any response whose request took more than 25 continuous seconds, before interpreting its status, server date, or retry headers. This covers suspension during sleep even if the networking framework resumes an old response after wake. Later delivery to the UI retains the original receipt instant, so queued results cannot acquire a new freshness timestamp. Failures back off from one minute to 15 minutes. HTTP 429 also respects Retry-After. Timer, wake, and manual requests share a 15-second minimum interval and never overlap. Manual refresh respects the same server rate-limit cooldown. Signing out is shown immediately. Rate limits and other temporary failures retain usable forecasts through 15 minutes of data age and dim them after three. A missing or older forecast shows Rate limited with the scheduled retry time, or Usage unavailable. The tooltip retains the error and exact retry time throughout the grace period; accessibility text also explains rate limits and the retry time. A separate UI check each minute updates freshness during backoff.

Only percentages, quota identifiers, observation dates, and reset dates are saved in `~/Library/Application Support/Headroom/history.json`, with owner-only file permissions. In memory, history retains about one hour and an earlier anchor, capped at the latest 256 consecutive observations. The disk cache contains only the latest snapshot. On launch, that snapshot is stale reference data and cannot supply rates or freshness. A live response starts fresh observations because elapsed time cannot be verified across app restarts. It can immediately supply a window-average estimate when its inferred window start is usable. Cache files larger than 256 KiB are ignored. If the in-memory bound removes older evidence, forecasting uses available observations or the initial-average fallback. Credentials stay in Keychain and transient process memory. Headroom does not start Claude, alter credentials, or refresh tokens. There is no analytics service.

The endpoint is internal. Response precision, quota behavior, and schema may change. Forecasts describe continued recent consumption, not future work schedules, exact token counts, or guaranteed access.
