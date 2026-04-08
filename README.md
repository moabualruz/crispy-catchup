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

## Current Limitations

- this crate does not fetch EPG or playback content
- vendor compatibility still depends on the quality of upstream metadata and templates

## License

See `LICENSE.md` and `NOTICE.md`.
