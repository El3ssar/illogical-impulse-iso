//! iictl-tui — the fancy ratatui renderer for the iictl chooser contract (#47).
//!
//! `iictl-tui <domain>` runs `iictl <domain> --spec` (the declarative option
//! spec), draws it with Material-You colours pulled live from the rice's
//! `colors.json`, and applies the user's picks by shelling back out to the
//! domain's `iictl` verbs — so it mutates NOTHING itself and every change still
//! flows through the bash engine + the ledger. The engine stays bash; this is
//! the interactive front-end only, and it is swappable (the same `--spec` JSON
//! also drives the Quickshell Control Center, #14).

mod app;
mod spec;
mod theme;

use std::env;
use std::error::Error;
use std::process::Command;

use spec::{Control, Spec};

type R<T> = Result<T, Box<dyn Error>>;

const USAGE: &str = "\
iictl-tui — interactive Material-You configurator for the iictl chooser contract

usage:
  iictl-tui <domain>          render <domain>'s spec and apply picks interactively
  iictl-tui --validate <dom>  parse + check the spec, print a summary, exit (no TUI)
  iictl-tui --version
  iictl-tui --help

env:
  IICTL              the iictl binary to invoke           (default: iictl)
  IICTL_TUI_SPEC     read the spec from this file instead of running iictl (testing)
  IICTL_TUI_COLORS   read Material-You colours from this colors.json (testing)
";

/// The iictl binary the renderer shells out to (overridable for tests).
fn iictl_bin() -> String {
    env::var("IICTL").unwrap_or_else(|_| "iictl".to_string())
}

/// Load a domain's spec — from `$IICTL_TUI_SPEC` (a file, for tests) or by
/// running `iictl <domain> --spec`. Public so the renderer can reload after an
/// apply to refresh the displayed `current` state.
///
/// The override is honored on EVERY call, including `App::apply`'s post-apply
/// reload — we re-read the env var and re-read the file each time rather than
/// caching, so a fixture that rewrites `$IICTL_TUI_SPEC` between applies sees the
/// fresh `current` (the override must not pin the spec to its launch-time state).
pub fn load_spec(domain: &str) -> R<Spec> {
    let json = if let Ok(path) = env::var("IICTL_TUI_SPEC") {
        std::fs::read_to_string(&path)
            .map_err(|e| format!("reading IICTL_TUI_SPEC ({path}): {e}"))?
    } else {
        let iictl = iictl_bin();
        let out = Command::new(&iictl)
            .arg(domain)
            .arg("--spec")
            .output()
            .map_err(|e| format!("running `{iictl} {domain} --spec`: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "`{iictl} {domain} --spec` exited {:?}",
                out.status.code()
            )
            .into());
        }
        String::from_utf8(out.stdout)?
    };
    let spec: Spec = serde_json::from_str(&json)
        .map_err(|e| format!("spec for '{domain}' is not valid against the contract: {e}"))?;
    Ok(spec)
}

/// `--validate` mode: parse the spec, assert it matches the contract, print a
/// human summary, and exit. No terminal, no apply — the Tier-0 contract check.
fn validate(domain: &str) -> R<()> {
    let spec = load_spec(domain)?;
    println!("domain : {}", spec.domain);
    println!("title  : {}", spec.title());
    println!("controls ({}):", spec.controls.len());
    if spec.controls.is_empty() {
        return Err("spec has no controls".into());
    }
    for c in &spec.controls {
        let (kind, detail) = match c {
            Control::Choice { options, .. } => ("choice", format!("{} option(s)", options.len())),
            Control::List {
                options,
                candidates,
                ..
            } => {
                let src = if candidates.is_empty() {
                    format!("{} inline option(s)", options.len())
                } else {
                    "dynamic candidates".to_string()
                };
                ("list", src)
            }
            Control::Toggle { .. } => ("toggle", "on/off".to_string()),
        };
        println!("  - {:<7} {:<22} {}", kind, c.label(), detail);
    }
    println!("\nok: spec is valid against the 3-control contract");
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        None => {
            eprint!("{USAGE}");
            std::process::exit(2);
        }
        Some("--help" | "-h") => {
            print!("{USAGE}");
            Ok(())
        }
        Some("--version" | "-V") => {
            println!("iictl-tui {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("--validate") => match args.get(1) {
            Some(domain) => validate(domain),
            None => Err("usage: iictl-tui --validate <domain>".into()),
        },
        Some(flag) if flag.starts_with('-') => {
            Err(format!("unknown flag '{flag}' (try --help)").into())
        }
        Some(domain) => {
            let spec = match load_spec(domain) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("iictl-tui: {e}");
                    std::process::exit(1);
                }
            };
            let theme = theme::Theme::load();
            app::App::new(domain.to_string(), iictl_bin(), spec, theme).run()
        }
    };

    if let Err(e) = result {
        eprintln!("iictl-tui: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // Regression for `spec-reload-ignores-tui-spec-override-doc`: a reload via
    // `load_spec` must RE-READ the `$IICTL_TUI_SPEC` file, so a fixture that
    // rewrites it between applies sees fresh `current` state (the override must
    // not pin the spec to its launch-time content). `set_var`/`remove_var` are
    // process-global, so serialize this test against itself.
    #[test]
    fn reload_rereads_tui_spec_override() {
        let dir = env::temp_dir();
        let path = dir.join(format!("iictl-tui-reload-{}.json", std::process::id()));

        let write = |current: &str| {
            let json = format!(
                r#"{{ "domain": "demo", "controls": [
                  {{ "id":"a","type":"choice","label":"A","current":"{current}",
                     "options":[{{"value":"x"}},{{"value":"y"}}],"apply":["demo","set","%v"] }}
                ] }}"#
            );
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(json.as_bytes()).unwrap();
        };

        // edition 2021: env::set_var is safe. Single-threaded test; we set and
        // clear the var within this test.
        env::set_var("IICTL_TUI_SPEC", &path);

        write("x");
        let s1 = load_spec("demo").unwrap();
        match &s1.controls[0] {
            Control::Choice { current, .. } => assert_eq!(current, "x"),
            _ => panic!("expected a choice control"),
        }

        // simulate state changing on disk between applies — the reload must see it.
        write("y");
        let s2 = load_spec("demo").unwrap();
        match &s2.controls[0] {
            Control::Choice { current, .. } => assert_eq!(current, "y"),
            _ => panic!("expected a choice control"),
        }

        env::remove_var("IICTL_TUI_SPEC");
        let _ = std::fs::remove_file(&path);
    }
}
