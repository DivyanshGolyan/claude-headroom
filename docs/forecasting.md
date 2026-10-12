# Forecasting

Headroom samples account quota approximately once a minute from `https://api.anthropic.com/api/oauth/usage`. This includes usage reflected by the server from other sessions and devices. It reads the Claude Code login stored in macOS Keychain through `/usr/bin/security`.

## Rates and thresholds

For each tracked quota window, calculate two rates from changes in its cumulative usage percentage:

- Short rate: the last 10 minutes.
- Long rate: the remaining time until reset, clamped to a lookback of 15–60 minutes.

Use the faster rate for both exhaustion and spare forecasts. This conservatively catches bursts, even when earlier observations include idle time. All observed time counts, including idle time. When there is less history than the lookback, use the available observations after a five-minute warm-up.

```text
remaining = 100 − latest usage percentage
exhaustion = latest observation time + remaining / rate
spare = remaining − rate × time from latest observation to reset
```

Any predicted shortfall immediately produces an outage warning. There is no product tolerance or delayed warning. Projected spare of at least 10% produces a spare label; anything from 0% to under 10% is On track. Floating-point roundoff is removed at one-billionth of a percentage point so exact boundaries stay exact.

Estimated exhaustion times round down to five minutes. Spare rounds down to five percentage points. Reset times retain their reported minute. Five-hour labels use the system's 12/24-hour convention with the meridiem removed. Weekly labels retain it in 12-hour locales and include the weekday when needed.

## Continuity and coverage

Keep observations through sleep and failed requests. Cumulative usage captures consumption between observations; interpolate an anchor at the lookback boundary. Across a long interruption this assumes uniform consumption over the missing interval, so the actual timing of a burst is unknown. A reset or a decreasing counter starts a fresh rate history for that quota window. Rates from an earlier window are not used as priors.

Five-hour quota drives spare estimates. Active, unscoped weekly limits and active Opus weekly limits also participate in outage detection. Other model-specific limits, such as Sonnet or Fable, are excluded. This policy suits Opus-heavy work; it is not a complete forecast for every model. Weekly counters need their own five minutes of observations, but a counter already at 100% warns immediately. Overlapping outages merge into the earliest continuous outage; the displayed end is when all overlapping limits have reset.

A null five-hour window, or zero utilization with no reset time, is treated as Ready. An absent required field, malformed reset, or invalid percentage is an error. The no-active-window interpretation is defensive handling of that response shape, not a guarantee about every server response.

## Freshness and storage

Requests time out after 25 seconds overall. Failures back off from one minute to 15 minutes. HTTP 429 also respects Retry-After. Manual refresh respects the same server rate-limit cooldown. Signing out is shown immediately. Other failures retain the previous forecast, dim it after three minutes, and show No data after ten. A separate UI check each minute updates freshness during backoff.

Only percentages, quota identifiers, observation dates, and reset dates are saved in `~/Library/Application Support/Headroom/history.json`, with owner-only file permissions. History retains about one hour and an earlier anchor. Credentials stay in Keychain and transient process memory. Headroom does not start Claude, alter credentials, or refresh tokens. There is no analytics service.

The endpoint is internal. Response precision, quota behavior, and schema may change. Forecasts describe continued recent consumption, not future work schedules, exact token counts, or guaranteed access.
