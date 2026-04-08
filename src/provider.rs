//! Provider-specific URL regex parsing for Flussonic and Xtream Codes.
//!
//! Translated from `Channel::GenerateFlussonicCatchupSource()` and
//! `Channel::GenerateXtreamCodesCatchupSource()` in `Channel.cpp`.

use regex::Regex;
use std::sync::LazyLock;
use url::Url;

use crate::error::CatchupError;

// ---------------------------------------------------------------------------
// Flussonic
// ---------------------------------------------------------------------------

/// Regex for well-defined Flussonic stream URLs.
///
/// Examples:
/// - `http://ch01.spr24.net/151/mpegts?token=my_token`
/// - `http://list.tv:8888/325/index.m3u8?token=secret`
/// - `http://list.tv:8888/325/mono.m3u8?token=secret`
static FLUSSONIC_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(https?://[^/]+)/(.*)/([^/]*)(mpegts|\.m3u8)(\?.+=.+)?$")
        .expect("flussonic regex")
});

/// Regex for generic Flussonic URLs (fallback).
///
/// Example: `http://list.tv:8888/325/live?token=my_token`
static FLUSSONIC_GENERIC_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(https?://[^/]+)/(.*)/([^\?]*)(\?.+=.+)?$").expect("flussonic generic regex")
});

/// Generate a Flussonic catchup source URL from a stream URL.
///
/// Returns `(catchup_source, is_ts_stream)`.
///
/// Translated from `Channel::GenerateFlussonicCatchupSource()` in `Channel.cpp`.
///
/// # Stream URL patterns
///
/// ```text
/// stream:  http://ch01.spr24.net/151/mpegts?token=my_token
/// catchup: http://ch01.spr24.net/151/timeshift_abs-${start}.ts?token=my_token
///
/// stream:  http://list.tv:8888/325/index.m3u8?token=secret
/// catchup: http://list.tv:8888/325/timeshift_rel-{offset:1}.m3u8?token=secret
///
/// stream:  http://list.tv:8888/325/mono.m3u8?token=secret
/// catchup: http://list.tv:8888/325/mono-timeshift_rel-{offset:1}.m3u8?token=secret
///
/// stream:  http://list.tv:8888/325/live?token=my_token
/// catchup: http://list.tv:8888/325/{utc}.ts?token=my_token
/// ```
pub fn generate_flussonic_source(
    url: &str,
    is_ts_hint: bool,
) -> Result<(String, bool), CatchupError> {
    // Try the well-defined regex first
    if let Some(caps) = FLUSSONIC_REGEX.captures(url) {
        let host = caps.get(1).map_or("", |m| m.as_str());
        let channel_id = caps.get(2).map_or("", |m| m.as_str());
        let list_type = caps.get(3).map_or("", |m| m.as_str());
        let stream_type = caps.get(4).map_or("", |m| m.as_str());
        let url_append = caps.get(5).map_or("", |m| m.as_str());

        let is_ts = stream_type == "mpegts";
        if is_ts {
            let source = format!("{host}/{channel_id}/timeshift_abs-${{start}}.ts{url_append}");
            return Ok((source, true));
        }

        let source = if list_type == "index" {
            format!("{host}/{channel_id}/timeshift_rel-{{offset:1}}.m3u8{url_append}")
        } else {
            format!("{host}/{channel_id}/{list_type}-timeshift_rel-{{offset:1}}.m3u8{url_append}")
        };
        return Ok((source, false));
    }

    // Fallback to generic regex
    if let Some(caps) = FLUSSONIC_GENERIC_REGEX.captures(url) {
        let host = caps.get(1).map_or("", |m| m.as_str());
        let channel_id = caps.get(2).map_or("", |m| m.as_str());
        let tail = caps.get(3).map_or("", |m| m.as_str()).to_ascii_lowercase();
        let url_append = caps.get(4).map_or("", |m| m.as_str());

        if is_ts_hint || tail == "mpegts" || tail.ends_with(".ts") {
            let source = format!("{host}/{channel_id}/timeshift_abs-${{start}}.ts{url_append}");
            return Ok((source, true));
        }

        let source = format!("{host}/{channel_id}/timeshift_rel-{{offset:1}}.m3u8{url_append}");
        return Ok((source, false));
    }

    if let Some(parsed) = parse_http_url(url) {
        let Some(segments) = non_empty_segments(&parsed) else {
            return Err(CatchupError::UrlParseFailed {
                provider: "Flussonic".to_string(),
                url: url.to_string(),
            });
        };
        if segments.len() >= 2 {
            let host = url_base(&parsed);
            let channel_path = segments[..segments.len() - 1].join("/");
            let tail = segments.last().copied().unwrap_or_default();
            let query_suffix = parsed.query().map(|q| format!("?{q}")).unwrap_or_default();

            let lower_tail = tail.to_ascii_lowercase();
            if is_ts_hint || lower_tail == "mpegts" || lower_tail.ends_with(".ts") {
                return Ok((
                    format!("{host}/{channel_path}/timeshift_abs-${{start}}.ts{query_suffix}"),
                    true,
                ));
            }

            let list_type = lower_tail
                .strip_suffix(".m3u8")
                .or_else(|| lower_tail.strip_suffix(".m3u"))
                .unwrap_or(&lower_tail);

            let source = if list_type == "index" || list_type == "live" {
                format!("{host}/{channel_path}/timeshift_rel-{{offset:1}}.m3u8{query_suffix}")
            } else {
                format!(
                    "{host}/{channel_path}/{list_type}-timeshift_rel-{{offset:1}}.m3u8{query_suffix}"
                )
            };
            return Ok((source, false));
        }
    }

    Err(CatchupError::UrlParseFailed {
        provider: "Flussonic".to_string(),
        url: url.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Xtream Codes
// ---------------------------------------------------------------------------

/// Regex for Xtream Codes stream URLs.
///
/// Examples:
/// - `http://list.tv:8080/my@account.xc/my_password/1477`
/// - `http://list.tv:8080/live/my@account.xc/my_password/1477.m3u8`
static XTREAM_CODES_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/\.]+)(\.m3u[8]?)?$")
        .expect("xtream codes regex")
});

/// Generate an Xtream Codes catchup source URL from a stream URL.
///
/// Returns `(catchup_source, is_ts_stream)`.
///
/// Translated from `Channel::GenerateXtreamCodesCatchupSource()` in `Channel.cpp`.
///
/// # Stream URL patterns
///
/// ```text
/// stream:  http://list.tv:8080/my@account.xc/my_password/1477
/// catchup: http://list.tv:8080/timeshift/my@account.xc/my_password/{duration:60}/{Y}-{m}-{d}:{H}-{M}/1477.ts
///
/// stream:  http://list.tv:8080/live/my@account.xc/my_password/1477.m3u8
/// catchup: http://list.tv:8080/timeshift/my@account.xc/my_password/{duration:60}/{Y}-{m}-{d}:{H}-{M}/1477.m3u8
/// ```
pub fn generate_xtream_codes_source(url: &str) -> Result<(String, bool), CatchupError> {
    if let Some(caps) = XTREAM_CODES_REGEX.captures(url) {
        let host = caps.get(1).map_or("", |m| m.as_str());
        let username = caps.get(2).map_or("", |m| m.as_str());
        let password = caps.get(3).map_or("", |m| m.as_str());
        let channel_id = caps.get(4).map_or("", |m| m.as_str());
        let extension = caps.get(5).map_or("", |m| m.as_str());

        let (ext, is_ts) = if extension.is_empty() {
            (".ts", true)
        } else {
            (extension, false)
        };

        let source = format!(
            "{host}/timeshift/{username}/{password}/{{duration:60}}/{{Y}}-{{m}}-{{d}}:{{H}}-{{M}}/{channel_id}{ext}"
        );
        return Ok((source, is_ts));
    }

    if let Some(parsed) = parse_http_url(url) {
        let Some(segments) = non_empty_segments(&parsed) else {
            return Err(CatchupError::UrlParseFailed {
                provider: "Xtream Codes".to_string(),
                url: url.to_string(),
            });
        };
        if segments.len() >= 3 {
            let host = url_base(&parsed);
            let username = segments[segments.len() - 3];
            let password = segments[segments.len() - 2];
            let stream_segment = segments[segments.len() - 1];

            let (channel_id, ext, is_ts) = if let Some(dot) = stream_segment.rfind('.') {
                let id = &stream_segment[..dot];
                let ext = &stream_segment[dot..];
                (id, ext, false)
            } else {
                (stream_segment, ".ts", true)
            };

            let source = format!(
                "{host}/timeshift/{username}/{password}/{{duration:60}}/{{Y}}-{{m}}-{{d}}:{{H}}-{{M}}/{channel_id}{ext}"
            );
            return Ok((source, is_ts));
        }
    }

    Err(CatchupError::UrlParseFailed {
        provider: "Xtream Codes".to_string(),
        url: url.to_string(),
    })
}

fn parse_http_url(raw: &str) -> Option<Url> {
    Url::parse(raw)
        .ok()
        .filter(|u| matches!(u.scheme(), "http" | "https"))
}

fn non_empty_segments(url: &Url) -> Option<Vec<&str>> {
    let segments: Vec<&str> = url
        .path_segments()?
        .filter(|segment| !segment.is_empty())
        .collect();
    if segments.is_empty() {
        None
    } else {
        Some(segments)
    }
}

fn url_base(url: &Url) -> String {
    match url.port() {
        Some(port) => format!(
            "{}://{}:{port}",
            url.scheme(),
            url.host_str().unwrap_or_default()
        ),
        None => format!("{}://{}", url.scheme(), url.host_str().unwrap_or_default()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Flussonic tests
    // -----------------------------------------------------------------------

    #[test]
    fn flussonic_mpegts_stream() {
        let (source, is_ts) =
            generate_flussonic_source("http://ch01.spr24.net/151/mpegts?token=my_token", false)
                .unwrap();
        assert!(is_ts);
        assert_eq!(
            source,
            "http://ch01.spr24.net/151/timeshift_abs-${start}.ts?token=my_token"
        );
    }

    #[test]
    fn flussonic_index_m3u8() {
        let (source, is_ts) =
            generate_flussonic_source("http://list.tv:8888/325/index.m3u8?token=secret", false)
                .unwrap();
        assert!(!is_ts);
        assert_eq!(
            source,
            "http://list.tv:8888/325/timeshift_rel-{offset:1}.m3u8?token=secret"
        );
    }

    #[test]
    fn flussonic_named_m3u8() {
        let (source, is_ts) =
            generate_flussonic_source("http://list.tv:8888/325/mono.m3u8?token=secret", false)
                .unwrap();
        assert!(!is_ts);
        assert_eq!(
            source,
            "http://list.tv:8888/325/mono-timeshift_rel-{offset:1}.m3u8?token=secret"
        );
    }

    #[test]
    fn flussonic_generic_hls() {
        let (source, is_ts) =
            generate_flussonic_source("http://list.tv:8888/325/live?token=my_token", false)
                .unwrap();
        assert!(!is_ts);
        assert_eq!(
            source,
            "http://list.tv:8888/325/timeshift_rel-{offset:1}.m3u8?token=my_token"
        );
    }

    #[test]
    fn flussonic_generic_ts_hint() {
        let (source, is_ts) =
            generate_flussonic_source("http://list.tv:8888/325/live?token=my_token", true).unwrap();
        assert!(is_ts);
        assert_eq!(
            source,
            "http://list.tv:8888/325/timeshift_abs-${start}.ts?token=my_token"
        );
    }

    #[test]
    fn flussonic_invalid_url() {
        let result = generate_flussonic_source("not-a-url", false);
        assert!(result.is_err());
    }

    #[test]
    fn flussonic_fallback_handles_ts_suffix() {
        let (source, is_ts) =
            generate_flussonic_source("http://list.tv:8888/325/live.ts?token=my_token", false)
                .unwrap();
        assert!(is_ts);
        assert_eq!(
            source,
            "http://list.tv:8888/325/timeshift_abs-${start}.ts?token=my_token"
        );
    }

    // -----------------------------------------------------------------------
    // Xtream Codes tests
    // -----------------------------------------------------------------------

    #[test]
    fn xtream_codes_no_extension() {
        let (source, is_ts) =
            generate_xtream_codes_source("http://list.tv:8080/my@account.xc/my_password/1477")
                .unwrap();
        assert!(is_ts);
        assert_eq!(
            source,
            "http://list.tv:8080/timeshift/my@account.xc/my_password/{duration:60}/{Y}-{m}-{d}:{H}-{M}/1477.ts"
        );
    }

    #[test]
    fn xtream_codes_m3u8_extension() {
        let (source, is_ts) = generate_xtream_codes_source(
            "http://list.tv:8080/live/my@account.xc/my_password/1477.m3u8",
        )
        .unwrap();
        assert!(!is_ts);
        assert_eq!(
            source,
            "http://list.tv:8080/timeshift/my@account.xc/my_password/{duration:60}/{Y}-{m}-{d}:{H}-{M}/1477.m3u8"
        );
    }

    #[test]
    fn xtream_codes_with_live_prefix() {
        let (source, _) =
            generate_xtream_codes_source("http://list.tv:8080/live/user/pass/1477").unwrap();
        assert!(source.contains("/timeshift/user/pass/"));
    }

    #[test]
    fn xtream_codes_fallback_handles_movie_prefix() {
        let (source, is_ts) =
            generate_xtream_codes_source("http://list.tv:8080/movie/user/pass/9001.mp4").unwrap();
        assert!(!is_ts);
        assert_eq!(
            source,
            "http://list.tv:8080/timeshift/user/pass/{duration:60}/{Y}-{m}-{d}:{H}-{M}/9001.mp4"
        );
    }

    #[test]
    fn xtream_codes_invalid_url() {
        let result = generate_xtream_codes_source("not-a-url");
        assert!(result.is_err());
    }
}
