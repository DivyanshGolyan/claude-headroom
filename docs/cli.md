# CLI contract

The `headroom` CLI reads the same monitoring engine as the running menu-bar app. It does not contact Anthropic, read Keychain, or write quota history. It requires the current user's app to be running. A separate background service is not installed.

```sh
headroom status
headroom refresh --timeout 30s
headroom status --format text
headroom status | jq '.data.observation.quotas[] | select(.kind == "five_hour")'
```

## Commands

`status` returns the current snapshot immediately without requesting an upstream fetch. Its forecast is evaluated at read time, so it can change as exhaustion, reset, or freshness boundaries pass.

`refresh` waits for a successful new observation, or joins a request already in progress. A server cooldown rejects it immediately with `rate_limited` and `retry_after_seconds`. It can bypass ordinary failure backoff, just like the menu's Refresh now. There is no force option that bypasses server cooldowns.

Both accept `--format json|text` and `--timeout SECONDS`. JSON is always the default, including in a terminal. Timeout defaults to 30 seconds; positive values up to 300 are accepted, with an optional `s` suffix. It bounds the complete connection, request, and response wait. A timeout or disconnected client does not cancel the app's shared fetch, which may finish later. `--help` prints command usage.

The CLI never starts the app implicitly. Open Headroom explicitly before querying it. An older app without CLI support also returns `app_not_running`; update the app and CLI together.

## JSON

Each invocation writes one JSON document followed by a newline to stdout. JSON failures use the same envelope. Human text errors go to stderr when `--format text` is selected.

```json
{
  "schema_version": 1,
  "data": {
    "observation": {
      "observed_at": "2026-10-12T09:30:00Z",
      "age_seconds": 74,
      "freshness": "fresh",
      "quotas": [
        {
          "kind": "five_hour",
          "used_percent": 62,
          "resets_at": "2026-10-12T12:00:00Z"
        }
      ]
    },
    "forecast": {
      "kind": "predicted_outage",
      "starts_at": "2026-10-12T11:10:00Z",
      "ends_at": "2026-10-12T12:00:00Z"
    },
    "update": {
      "in_progress": false,
      "last_error": null,
      "retry_after_seconds": null
    }
  },
  "error": null
}
```

`data` and `error` are always present. `data` is null when the command cannot read the app. Failed refreshes can return a retained snapshot alongside a non-null error. A retained snapshot is not evidence of refresh success.

`observation` is null until the app has live or saved quota data. Percentages are numbers between 0 and 100. Dates use RFC 3339 UTC at second precision, without the menu's five-minute rounding. Quota `kind` values are `five_hour`, `seven_day`, and `seven_day_opus`. They describe categories, not unique upstream identifiers; several weekly quotas can share a category. A missing `resets_at` on `five_hour` means no active session window in that observation. An elapsed reset remains visible as historical data; consult the forecast for current interpretation.

`age_seconds` uses the app's continuous clock, including sleep. Do not derive freshness by subtracting your system clock from `observed_at`. Freshness is `fresh` through six minutes, `aging` through fifteen, and `stale` thereafter. A restored disk observation has `unknown` freshness and null age, and cannot supply a usable forecast until a live fetch.

Forecast fields depend on `kind`:

| Kind | Meaning and fields |
|---|---|
| `measuring` | No usable rate or observation yet. |
| `waiting_for_usage` | The previous window ended; replacement usage has not arrived. |
| `unavailable` | No actionable forecast. `reason` identifies `stale`, `signed_out`, `rate_limited`, or `usage_unavailable`. |
| `ready` | No active five-hour window, or zero usage without a measured rate. |
| `on_track` | No predicted outage and less than 10% projected spare. |
| `spare` | `estimated_spare_percent` at `ends_at`. The estimate is rounded down to five percentage points, matching the app. |
| `predicted_outage` | A future predicted outage between `starts_at` and `ends_at`. |
| `likely_outage` | Predicted exhaustion has arrived, but exhaustion for the full period through `ends_at` is not confirmed. |
| `outage` | Observed exhausted quota accounts for the outage through `ends_at`. |

Forecasts retain the app's quota coverage and assumptions; see [Forecasting](forecasting.md). A temporary fetch failure can coexist with a usable forecast. Signing out suppresses the actionable forecast immediately while retaining the last observation for inspection.

`update.last_error` describes the latest fetch failure, independently of whether reading status succeeded. `update.retry_after_seconds` is the remaining server cooldown, or null when no cooldown is active. It is not the next automatic polling interval. Any `retry_after_seconds` is a duration measured when the response was created.

Consumers must tolerate added object fields. Changes to existing field meanings or forecast variants require a schema version change. The app and CLI reject incompatible versions. The public JSON is deliberately separate from provider responses, disk storage, and Swift enum encoding.

## Errors and exit codes

| Exit code | Meaning |
|---|---|
| `0` | The operation completed. Status can report stale data or fetch problems; exhausted quota is also a successful status read. |
| `1` | The operation failed. Read `error.code` for the cause. |
| `2` | Invalid command-line arguments. |

Error objects contain `code`, `message`, and optionally `retry_after_seconds`. Treat the code as stable and the message as explanatory prose. Codes include `invalid_arguments`, `app_not_running`, `signed_out`, `rate_limited`, `usage_unavailable`, `timeout`, `connection_error`, `protocol_mismatch`, `invalid_request`, and `encoding_error`.

For authentication, run `claude auth login`, then `headroom refresh`. The CLI does not launch an interactive login itself. After a timeout or connection loss, `headroom status` can inspect whether the shared request completed; a failed connection does not prove that a refresh never started.

## Installation and transport

Source builds produce `build/headroom`. Distributed apps contain `Headroom.app/Contents/Helpers/headroom`; the Homebrew cask links it into the Homebrew binary directory when the release includes that executable. Downloaded installations can run it directly or link it into an existing directory on `PATH`.

The app accepts one bounded request per local Unix socket connection. A private directory and socket permissions restrict access to the current user; both ends also check the peer's user ID. A process lock prevents a second supported app instance from replacing the active endpoint. Stale sockets are removed only after acquiring that lock. Socket I/O runs outside the app's main thread, and the server limits concurrent connections. The socket location and framing are implementation details; scripts should use the CLI.
