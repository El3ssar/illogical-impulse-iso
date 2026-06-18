//! The iictl chooser contract — the declarative option spec every domain verb
//! emits as `iictl <verb> --spec` (JSON). This module is the renderer-side
//! mirror of that contract: serde structs + the tiny argv-substitution rule.
//!
//! The contract is deliberately small (the anti-clutter ceiling): EXACTLY three
//! control types — `choice`, `list`, `toggle`. Every mutating field is an
//! `iictl` argv array the renderer runs verbatim with two placeholders:
//!   %v  → the chosen value
//!   %s  → the chosen source (list controls with dynamic `candidates` only)
//! The renderer NEVER mutates state itself; it only shells out to these argv,
//! so every change still flows through the domain's bash verbs and the ledger.

use serde::Deserialize;

/// One domain's full configurable surface.
#[derive(Debug, Clone, Deserialize)]
pub struct Spec {
    /// The iictl verb this spec belongs to (e.g. "pack"). Apply argv are run as
    /// `iictl <argv...>`, so they begin with this verb.
    #[allow(dead_code)]
    pub domain: String,
    /// Human title for the panel header. Falls back to `domain` when absent.
    #[serde(default)]
    pub title: String,
    pub controls: Vec<Control>,
}

impl Spec {
    pub fn title(&self) -> &str {
        if self.title.is_empty() {
            &self.domain
        } else {
            &self.title
        }
    }
}

/// A single selectable option (value + optional human label).
#[derive(Debug, Clone, Deserialize)]
pub struct Opt {
    pub value: String,
    #[serde(default)]
    pub label: Option<String>,
}

impl Opt {
    pub fn label(&self) -> &str {
        self.label.as_deref().unwrap_or(&self.value)
    }
}

/// The three control types, internally tagged by the `type` field.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Control {
    /// Single selection from a fixed set. The primary control type — progressive
    /// disclosure puts a domain's main choice first.
    Choice {
        #[allow(dead_code)]
        id: String,
        label: String,
        #[serde(default)]
        current: String,
        options: Vec<Opt>,
        /// argv applied with %v = chosen value.
        apply: Vec<String>,
    },
    /// Multi-selection (add/remove) over a candidate set. Candidates come from
    /// inline `options` OR, for source-driven domains (#48), a dynamic
    /// `candidates` argv resolved per `source` (%s).
    List {
        #[allow(dead_code)]
        id: String,
        label: String,
        #[serde(default)]
        current: Vec<String>,
        #[serde(default)]
        options: Vec<Opt>,
        #[serde(default)]
        sources: Vec<String>,
        #[serde(default)]
        candidates: Vec<String>,
        /// argv applied with %v = value to ADD.
        apply_add: Vec<String>,
        /// argv applied with %v = value to REMOVE.
        apply_remove: Vec<String>,
    },
    /// A boolean switch.
    Toggle {
        #[allow(dead_code)]
        id: String,
        label: String,
        #[serde(default)]
        current: bool,
        apply_on: Vec<String>,
        apply_off: Vec<String>,
    },
}

impl Control {
    pub fn label(&self) -> &str {
        match self {
            Control::Choice { label, .. }
            | Control::List { label, .. }
            | Control::Toggle { label, .. } => label,
        }
    }
}

/// Substitute the `%v` (value) and `%s` (source) placeholders in an argv
/// template. A token may contain a placeholder as a substring (e.g. `"pack:%v"`).
pub fn subst(argv: &[String], value: &str, source: Option<&str>) -> Vec<String> {
    argv.iter()
        .map(|tok| {
            let tok = tok.replace("%v", value);
            match source {
                Some(s) => tok.replace("%s", s),
                None => tok,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PACK_SPEC: &str = r#"
    { "domain": "pack", "title": "Optional packs", "controls": [
      { "id": "packs", "type": "list", "label": "Installed packs",
        "current": ["gaming"],
        "options": [ {"value":"gaming","label":"gaming"}, {"value":"virt"} ],
        "apply_add": ["pack","install","%v"], "apply_remove": ["pack","remove","%v"] }
    ] }"#;

    #[test]
    fn parses_pack_list_spec() {
        let spec: Spec = serde_json::from_str(PACK_SPEC).unwrap();
        assert_eq!(spec.domain, "pack");
        assert_eq!(spec.title(), "Optional packs");
        assert_eq!(spec.controls.len(), 1);
        match &spec.controls[0] {
            Control::List {
                current,
                options,
                apply_add,
                apply_remove,
                ..
            } => {
                assert_eq!(current, &vec!["gaming".to_string()]);
                assert_eq!(options.len(), 2);
                // missing label falls back to value
                assert_eq!(options[1].label(), "virt");
                assert_eq!(apply_add, &vec!["pack", "install", "%v"]);
                assert_eq!(apply_remove, &vec!["pack", "remove", "%v"]);
            }
            _ => panic!("expected a list control"),
        }
    }

    #[test]
    fn parses_all_three_control_types() {
        let json = r#"
        { "domain": "demo", "controls": [
          { "id":"a","type":"choice","label":"A","current":"x",
            "options":[{"value":"x"},{"value":"y"}],"apply":["demo","set","%v"] },
          { "id":"b","type":"list","label":"B","current":[],
            "sources":["git"],"candidates":["demo","cand","%s"],
            "apply_add":["demo","add","%v"],"apply_remove":["demo","rm","%v"] },
          { "id":"c","type":"toggle","label":"C","current":true,
            "apply_on":["demo","on"],"apply_off":["demo","off"] }
        ] }"#;
        let spec: Spec = serde_json::from_str(json).unwrap();
        assert_eq!(spec.controls.len(), 3);
        assert!(matches!(spec.controls[0], Control::Choice { .. }));
        assert!(matches!(spec.controls[1], Control::List { .. }));
        assert!(matches!(spec.controls[2], Control::Toggle { .. }));
    }

    #[test]
    fn subst_replaces_value_and_source() {
        let argv = vec![
            "pack".to_string(),
            "install".to_string(),
            "%v".to_string(),
        ];
        assert_eq!(subst(&argv, "gaming", None), vec!["pack", "install", "gaming"]);

        let cand = vec!["shell".to_string(), "candidates".to_string(), "%s".to_string()];
        assert_eq!(
            subst(&cand, "", Some("antidote")),
            vec!["shell", "candidates", "antidote"]
        );

        // placeholder as a substring of a token
        let pref = vec!["revert".to_string(), "pack:%v".to_string()];
        assert_eq!(subst(&pref, "gaming", None), vec!["revert", "pack:gaming"]);
    }

    #[test]
    fn unknown_type_is_rejected() {
        let json = r#"{ "domain":"x","controls":[{"id":"a","type":"slider","label":"A"}] }"#;
        assert!(serde_json::from_str::<Spec>(json).is_err());
    }
}
