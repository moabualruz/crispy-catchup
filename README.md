# crispy-catchup

Catchup and timeshift URL helpers for IPTV streams.

## What This Crate Is

`crispy-catchup` encapsulates catchup-mode parsing and URL generation for IPTV channels that support archive playback, timeshift playback, or VOD-style catchup flows.

## What It Provides

- catchup mode resolution
- provider-specific source parsing
- time-placeholder template expansion
- helpers for:
  - timeshift playback
  - VOD catchup playback
  - live playback with “now” placeholders
- catchup window validation

## Installation

```toml
[dependencies]
crispy-catchup = "0.1.1"
```

MSRV: Rust `1.85`

## Quick Start

```rust
use crispy_catchup::{CatchupConfig, CatchupMode};

let config = CatchupConfig {
    mode: CatchupMode::Default,
    source: "http://example.com/archive/{utc}".into(),
    catchup_days: 7,
    supports_timeshifting: true,
    terminates: true,
    granularity_seconds: 60,
    is_ts_stream: false,
};

assert_eq!(config.catchup_days, 7);
```

## Typical Uses

- archive playback URL generation
- EPG-driven timeshift playback
- provider catchup compatibility layers

## Deterministic Time Semantics

Formatting is driven by explicit offset input, not the host machine's local timezone.
That means the same inputs produce the same formatted output regardless of where the
caller is running.

## Supported Provider Shapes

The crate currently includes provider-oriented helpers for:

- Flussonic-style live/catchup URL derivation
- Xtream Codes-style live/movie/series stream URL derivation

These helpers now use a broader URL-structure fallback path in addition to the
well-known fast-path regexes, so common provider variants are less likely to fail
just because the exact path shape differs from one canonical example.

## Current Limitations

- this crate does not fetch EPG or playback content
- vendor compatibility still depends on upstream metadata quality and template correctness
- some providers use highly custom archive URL semantics that still need caller-side handling

## License

See `LICENSE.md` and `NOTICE.md`.
