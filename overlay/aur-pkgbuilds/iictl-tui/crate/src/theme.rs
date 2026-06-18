//! Material-You theming for the renderer. Reads the SAME read-only
//! `colors.json` the rice generates (`~/.local/state/quickshell/user/generated/
//! colors.json`) so the TUI re-themes with the wallpaper, exactly like the
//! welcome card and the Control Center (#14). The file is upstream-owned runtime
//! STATE: we only ever READ it, never seed or write it. A static fallback
//! (the welcome-card palette) keeps the renderer usable before first-run colour
//! generation, on a TTY with no rice, or if the file is missing/malformed.

use ratatui::style::Color;
use std::collections::HashMap;
use std::path::PathBuf;

pub struct Theme {
    pub background: Color,
    pub surface: Color,
    pub surface_container: Color,
    pub primary: Color,
    pub on_primary: Color,
    pub primary_container: Color,
    pub on_primary_container: Color,
    pub on_surface: Color,
    pub on_surface_variant: Color,
    pub outline: Color,
    pub error: Color,
}

impl Theme {
    /// The static fallback — the welcome card's Catppuccin-ish palette. Used
    /// verbatim when colours can't be read so the TUI always looks intentional.
    pub fn fallback() -> Theme {
        Theme {
            background: Color::Rgb(0x1E, 0x20, 0x2B),
            surface: Color::Rgb(0x23, 0x28, 0x3A),
            surface_container: Color::Rgb(0x28, 0x2E, 0x3D),
            primary: Color::Rgb(0x45, 0xDD, 0xBC),
            on_primary: Color::Rgb(0x16, 0x28, 0x1F),
            primary_container: Color::Rgb(0x32, 0x38, 0x48),
            on_primary_container: Color::Rgb(0xCD, 0xD6, 0xF4),
            on_surface: Color::Rgb(0xCD, 0xD6, 0xF4),
            on_surface_variant: Color::Rgb(0x8E, 0x95, 0xB3),
            outline: Color::Rgb(0x3A, 0x41, 0x54),
            error: Color::Rgb(0xF3, 0x8B, 0xA8),
        }
    }

    /// Load colours, falling back field-by-field to the static palette so a
    /// partial/older `colors.json` still themes everything.
    pub fn load() -> Theme {
        match read_colors() {
            Some(map) => Theme::from_map(&map),
            None => Theme::fallback(),
        }
    }

    fn from_map(map: &HashMap<String, String>) -> Theme {
        let fb = Theme::fallback();
        let pick = |key: &str, default: Color| -> Color {
            map.get(key).and_then(|h| parse_hex(h)).unwrap_or(default)
        };
        Theme {
            background: pick("background", fb.background),
            surface: pick("surface", fb.surface),
            surface_container: pick("surface_container", fb.surface_container),
            primary: pick("primary", fb.primary),
            on_primary: pick("on_primary", fb.on_primary),
            primary_container: pick("primary_container", fb.primary_container),
            on_primary_container: pick("on_primary_container", fb.on_primary_container),
            on_surface: pick("on_surface", fb.on_surface),
            on_surface_variant: pick("on_surface_variant", fb.on_surface_variant),
            outline: pick("outline", fb.outline),
            error: pick("error", fb.error),
        }
    }
}

/// Where the rice writes its generated Material-You palette. Honour
/// `$XDG_STATE_HOME`, then fall back to `$HOME/.local/state`. An explicit
/// `IICTL_TUI_COLORS` override exists for tests.
fn colors_path() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("IICTL_TUI_COLORS") {
        return Some(PathBuf::from(p));
    }
    let base = std::env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .ok()?;
    Some(base.join("quickshell/user/generated/colors.json"))
}

fn read_colors() -> Option<HashMap<String, String>> {
    let path = colors_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<HashMap<String, String>>(&text).ok()
}

/// Parse `#rrggbb` (or `#rgb`) into a ratatui RGB colour.
fn parse_hex(s: &str) -> Option<Color> {
    let h = s.trim().strip_prefix('#')?;
    let (r, g, b) = match h.len() {
        6 => (
            u8::from_str_radix(&h[0..2], 16).ok()?,
            u8::from_str_radix(&h[2..4], 16).ok()?,
            u8::from_str_radix(&h[4..6], 16).ok()?,
        ),
        3 => {
            let r = u8::from_str_radix(&h[0..1], 16).ok()?;
            let g = u8::from_str_radix(&h[1..2], 16).ok()?;
            let b = u8::from_str_radix(&h[2..3], 16).ok()?;
            (r * 17, g * 17, b * 17)
        }
        _ => return None,
    };
    Some(Color::Rgb(r, g, b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_six_digit_hex() {
        assert_eq!(parse_hex("#95cdf7"), Some(Color::Rgb(0x95, 0xcd, 0xf7)));
        assert_eq!(parse_hex("  #000000 "), Some(Color::Rgb(0, 0, 0)));
    }

    #[test]
    fn parses_three_digit_hex() {
        assert_eq!(parse_hex("#fff"), Some(Color::Rgb(255, 255, 255)));
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(parse_hex("nope"), None);
        assert_eq!(parse_hex("#12"), None);
        assert_eq!(parse_hex("#gggggg"), None);
    }

    #[test]
    fn from_map_falls_back_per_field() {
        let mut m = HashMap::new();
        m.insert("primary".to_string(), "#ff0000".to_string());
        // everything else missing → fallback values
        let t = Theme::from_map(&m);
        assert_eq!(t.primary, Color::Rgb(0xff, 0, 0));
        assert_eq!(t.on_surface, Theme::fallback().on_surface);
    }
}
