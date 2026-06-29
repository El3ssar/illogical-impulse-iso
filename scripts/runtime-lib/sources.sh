# sources.sh — the multi-source list-manager substrate (#48).
#
# Staged to /usr/local/lib/ii/sources.sh (a survive-path — kept by ii-verify so
# the installed system's list manager works). Sourced by iictl.d/ verbs that
# present a #47 `list` control over a *caller-supplied manifest path* whose
# candidates come from one of several ecosystems (the first is zsh plugins:
# antidote bundles, Oh My Zsh plugins, raw git repos). set -u-safe and
# side-effect-free on source (defines functions + namespaced II_SOURCES* consts).
#
# ── Why a substrate (and not per-domain fetching) ────────────────────────────
# The shell layer (#15) and any future "curated list you add to" needs to pick
# items from multiple ecosystems WITHOUT each domain re-implementing source
# fetching. This file is the reusable engine: it discovers drop-in *source
# resolvers* and routes a domain's add/remove/list through the shared ledger so
# every change is reversible. The picker UX is the one shared `iictl-tui`
# renderer (#47) — no domain opens a second fzf/skim picker.
#
# ── The source-resolver drop-in contract ────────────────────────────────────
# A source named <name> is ONE file at $II_SOURCES_D/<name> (the iictl.d/ model
# applied to sources — adding an ecosystem is one file, no hardcoded list, no
# renderer edit). The file is SOURCED (a bash fragment, like a pack hook — not
# executed), so mkarchiso's +x mode-strip can never disarm it, and it inherits
# the colors/helpers already in scope. It MUST define these four functions
# (each prefixed ii_source_<name>_):
#
#   ii_source_<name>_candidates           # print, one per line, candidate ENTRIES
#                                          # (each line is the EXACT manifest line
#                                          # to add — self-describing, so the
#                                          # source-agnostic `add`/`remove` verbs
#                                          # take just the entry, never the source).
#   ii_source_<name>_add    <manifest> <entry>   # append <entry> to <manifest> (idempotent)
#   ii_source_<name>_remove <manifest> <entry>   # drop <entry> from <manifest>   (idempotent)
#   ii_source_<name>_current <manifest>          # print the manifest entries this
#                                                # source recognises (for the
#                                                # `list` control's `current[]`).
#
# The default add/remove/current are plain manifest line ops shared by every
# source (ii_manifest_add / ii_manifest_remove / ii_manifest_current); a resolver
# only overrides them if its entries need special handling. A resolver that wants
# the defaults declares nothing beyond `ii_source_<name>_candidates` and lets the
# manager fall through to the manifest helpers — see _ii_source_call.
#
# The candidate value IS the manifest line because #47's renderer applies
# add/remove with %v (the chosen value) and DOES NOT pass the source to the apply
# argv (app.rs: apply_add/apply_remove run `subst(argv, value, None)`). Encoding
# the source into the value keeps add/remove source-agnostic and matches the pack
# domain's "value == thing to act on" shape exactly.

II_LIB="${II_LIB:-/usr/local/lib/ii}"
# Where the source-resolver drop-ins ride (overridable for the no-root unit test).
II_SOURCES_D="${II_SOURCES_D:-$II_LIB/sources.d}"

# Source the ledger so the manifest mutators can record reversible rows. Guarded
# so a dev checkout without the staged tree still loads; double-source is safe.
[[ -r "$II_LIB/ledger.sh" ]] && source "$II_LIB/ledger.sh"

# ── manifest line helpers (the default add/remove/current every source shares) ─
# A manifest is a plain text file, one entry per line; blank lines and lines
# beginning with '#' are ignored (comments/headers). Entries are matched and
# de-duplicated on their EXACT text (trailing whitespace trimmed). No jq, no sed
# for the data path — pure bash so the substrate carries no new dependency.

# _ii_manifest_lines <manifest> — print the non-blank, non-comment entries.
_ii_manifest_lines() {
  local f="$1" line
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"   # rstrip
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" == '#'* ]] && continue
    printf '%s\n' "$line"
  done < "$f"
}

# ii_manifest_current <manifest> — every recognised entry (the default source
# `current` when a resolver does not narrow it).
ii_manifest_current() { _ii_manifest_lines "$1"; }

# ii_manifest_has <manifest> <entry> — true if <entry> is already present.
ii_manifest_has() {
  local f="$1" entry="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$entry" ]] && return 0
  done < <(_ii_manifest_lines "$f")
  return 1
}

# ii_manifest_add <manifest> <entry> — append <entry> idempotently. Creates the
# manifest dir/file on first use. Returns 0 and prints nothing on a no-op (already
# present) so the caller can detect "nothing changed". Records nothing itself —
# the BASELINE row + reversibility is owned by the manager (ii_manifest_baseline).
ii_manifest_add() {
  local f="$1" entry="$2"
  [[ -n "$entry" ]] || return 1
  ii_manifest_has "$f" "$entry" && return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf '%s\n' "$entry" >> "$f" 2>/dev/null || return 1
}

# ii_manifest_remove <manifest> <entry> — drop every exact-match line. Idempotent
# (no-op if absent). Atomic rewrite via a temp file so a crash never truncates.
ii_manifest_remove() {
  local f="$1" entry="$2" line tmp
  [[ -f "$f" ]] || return 0
  ii_manifest_has "$f" "$entry" || return 0
  tmp="$(mktemp)" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    local trimmed="${line%$'\r'}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ "$trimmed" == "$entry" ]] && continue
    printf '%s\n' "$line"
  done < "$f" > "$tmp"
  cat "$tmp" > "$f" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
}

# ── reversibility: record the manifest baseline ONCE (ledger) ────────────────
# The manifest is ENTIRELY ii-owned (an unowned/excluded slot — never an
# upstream-shipped path), so reverting to vanilla means: restore whatever the
# manifest looked like before the user's first edit, or remove it if it did not
# exist. Both reuse an EXISTING revert-all inverse — no new ledger kind:
#   • manifest existed (a curated baseline) → snapshot it to a sibling backup and
#     record a `skel-shadow` row. revert-all's skel-shadow inverse does
#     `cp -a <restore_hint backup> <F_target>`, so F_target MUST be the real
#     manifest path (NOT a synthetic key) and restore_hint the backup path.
#     Restores the baseline lines exactly.
#   • manifest absent → record a `file` row owning the manifest path (revert-all's
#     file inverse `rm -f`s owned_paths). Removing it ⇒ vanilla; the antidote load
#     line no-ops when absent.
# Recorded ONCE per manifest (idempotent — keyed on the manifest path as the
# ledger target), BEFORE the first mutation, so the very first add/remove is
# itself reversible. The target IS the manifest path so the per-feature filter
# (`iictl revert-all <manifest>` / `iictl plugins --revert`) selects exactly this
# manifest's rows; a bare `iictl revert-all` sweeps it too.
#
# ii_manifest_baseline <manifest> — ensure the baseline row exists. No-op if
# already recorded. Safe to call before every mutation.
ii_manifest_baseline() {
  local f="$1"
  # Already recorded? (skel-shadow or file row whose target is this manifest.)
  if [[ -n "$(ledger_query skel-shadow "$f" 2>/dev/null)" ]] \
  || [[ -n "$(ledger_query file       "$f" 2>/dev/null)" ]]; then
    return 0
  fi
  if [[ -f "$f" ]]; then
    # Curated baseline present → back it up, record a skel-shadow restore row.
    # F_target = the manifest (skel-shadow cp -a's restore_hint→target on revert);
    # restore_hint = the backup path; owned_paths = the backup too, so a full
    # revert also rm's the backup sidecar (path inverse rm's owned_paths) only
    # AFTER restoring — skel-shadow runs first (cp), the leftover backup is the
    # one the same row owns, removed when the row is dropped is N/A; the backup is
    # intentionally left for re-revert safety. Keep owned_paths empty to avoid
    # the file inverse fighting the skel-shadow restore.
    local backup
    backup="$(dirname "$f")/.$(basename "$f").ii-baseline"
    cp -a "$f" "$backup" 2>/dev/null || return 0
    ledger_record skel-shadow "$f" "$(_ii_source_pack_tag)" "" "$backup"
  else
    # No baseline → the whole manifest is ours; a `file` row removes it on revert.
    ledger_record file "$f" "$(_ii_source_pack_tag)" \
      "$(ledger_escape_path "$f")" "rm to restore vanilla (no manifest baseline)"
  fi
}

# Pack-tag passthrough (REV-04): if a pack post-add hook ever drives a list add,
# stamp II_PACK_TAG into the row's packages column so `revert-all pack:<name>`
# sweeps it with the pack. Empty (the common iictl-time case) → unchanged.
_ii_source_pack_tag() { printf '%s' "${II_PACK_TAG:-}"; }

# ── source discovery + dispatch (no hardcoded source list) ───────────────────
# ii_sources_list — print the available source names (the drop-in basenames),
# sorted. Adding a resolver file makes a new source appear here with zero edits.
ii_sources_list() {
  local p name
  [[ -d "$II_SOURCES_D" ]] || return 0
  for p in "$II_SOURCES_D"/*; do
    [[ -f "$p" ]] || continue
    name="$(basename "$p")"
    case "$name" in .*|*.disabled) continue ;; esac   # skip dotfiles / disabled
    printf '%s\n' "$name"
  done | sort -u
}

# ii_source_exists <name> — true if the named resolver drop-in is present.
ii_source_exists() {
  local name="$1"
  [[ -n "$name" && -f "$II_SOURCES_D/$name" ]]
}

# _ii_source_load <name> — source the resolver drop-in for <name> exactly once
# per process. The fragment defines ii_source_<name>_candidates (+ optionally
# add/remove/current overrides). Returns non-zero if the drop-in is missing.
declare -A _II_SOURCE_LOADED=()
_ii_source_load() {
  local name="$1"
  ii_source_exists "$name" || return 1
  [[ -n "${_II_SOURCE_LOADED[$name]:-}" ]] && return 0
  # shellcheck source=/dev/null
  source "$II_SOURCES_D/$name" || return 1
  _II_SOURCE_LOADED["$name"]=1
  return 0
}

# _ii_source_call <name> <op> [args...] — dispatch <op> (candidates|add|remove|
# current) to the resolver, falling back to the shared manifest helper when the
# resolver does not override add/remove/current. `candidates` has NO default — a
# resolver MUST define it (there is nothing universal to enumerate).
_ii_source_call() {
  local name="$1" op="$2"; shift 2
  _ii_source_load "$name" || { _ii_source_err "unknown source '$name'"; return 1; }
  local fn="ii_source_${name}_${op}"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
    return $?
  fi
  case "$op" in
    add)     ii_manifest_add     "$@" ;;
    remove)  ii_manifest_remove  "$@" ;;
    current) ii_manifest_current "$@" ;;
    *)       _ii_source_err "source '$name' does not implement '$op'"; return 1 ;;
  esac
}

# Self-contained error helper (sources.sh is sourced standalone in tests and by
# verbs that may or may not have iictl-common's die in scope).
_ii_source_err() { printf 'ii-sources: %s\n' "$*" >&2; }
