# crispy-catchup

Catchup and timeshift URL helpers for IPTV streams.

## Status

Extracted from CrispyTivi. Intended as a reusable Rust crate for catchup URL construction and validation.

## What This Crate Provides

- catchup mode handling
- provider-specific source parsing
- template-based catchup URL formatting
- live/timeshift/VOD catchup helpers
- catchup-window validation

## Installation

```toml
[dependencies]
crispy-catchup = "0.1"
```

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
};

assert_eq!(config.catchup_days, 7);
```

## Primary Use Cases

- IPTV playback backends
- EPG-driven timeshift playback
- archive URL generation

## Relationship To Other Crates

- uses `crispy-iptv-types`
- often complements parser/client crates that surface catchup metadata

## Caveats

- public docs should include vendor compatibility notes and placeholder semantics before release
