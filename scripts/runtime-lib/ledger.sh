# ledger.sh — append-only TSV state ledger.
#
# Staged to /usr/local/lib/ii/ledger.sh; sourced by iictl-common.sh (and thus by
# iictl + every iictl.d/ plugin), by mutator.sh, and by ii-post-install. It is
# the single machine-checkable manifest of every reversible change the distro
# makes: `iictl revert-all` (#4) replays it in reverse to restore byte-for-byte
# vanilla. Plain TSV — NO jq, NO JSON — so the replay engine parses with awk/cut
# (already present) and never bakes a dependency just for undo bookkeeping.
# set -u-safe and side-effect-free on source (defines functions + namespaced
# II_LEDGER* constants only).
#
# Schema (one row per reversible action), tab-separated, with a header comment:
#   ts <TAB> kind <TAB> target <TAB> packages <TAB> owned_paths <TAB> restore_hint
# owned_paths is a comma-separated list; packages is space-separated. Every field
# is sanitized TAB/newline-free so a row is always exactly one line of six cols.
#
# No-op-safe by contract: a plugin must NEVER die because the ledger could not be
# written, so write paths return 0 even when the state dir is unwritable.

II_LEDGER_DIR="${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/illogical-impulse"
II_LEDGER="$II_LEDGER_DIR/ledger.tsv"

# _ledger_init — ensure the state dir + the ledger file (with a header comment)
# exist. Returns non-zero if the dir is unwritable so callers can no-op.
_ledger_init() {
  mkdir -p "$II_LEDGER_DIR" 2>/dev/null || return 1
  [[ -f "$II_LEDGER" ]] && return 0
  printf '# ts\tkind\ttarget\tpackages\towned_paths\trestore_hint\n' \
    > "$II_LEDGER" 2>/dev/null || return 1
}

# _ledger_sanitize <field> — collapse any TAB/newline/CR to a single space so
# every recorded row stays one TAB-delimited line of exactly six columns. Pure
# bash parameter expansion — no tr/sed dependency.
_ledger_sanitize() {
  local s="${1:-}"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '%s' "$s"
}

# ledger_record <kind> <target> [packages] [owned_paths] [restore_hint]
# Append one row (append-only — never rewrites). No-op-safe: a missing kind or
# an unwritable state dir returns 0 rather than aborting the caller.
ledger_record() {
  local kind="${1:-}" target="${2:-}" packages="${3:-}" owned_paths="${4:-}" hint="${5:-}"
  [[ -n "$kind" ]] || return 0
  _ledger_init || return 0
  kind="$(_ledger_sanitize "$kind")"
  target="$(_ledger_sanitize "$target")"
  packages="$(_ledger_sanitize "$packages")"
  owned_paths="$(_ledger_sanitize "$owned_paths")"
  hint="$(_ledger_sanitize "$hint")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$kind" "$target" "$packages" "$owned_paths" "$hint" \
    >> "$II_LEDGER" 2>/dev/null || return 0
}

# ledger_query [kind] [target] — echo matching data rows (the header comment is
# always skipped). No filter → all rows; kind only → rows of that kind; kind +
# target → rows matching both. Used by `iictl doctor` and `revert-all` (#4).
ledger_query() {
  [[ -f "$II_LEDGER" ]] || return 0
  local kind="${1:-}" target="${2:-}"
  awk -F'\t' -v k="$kind" -v t="$target" '
    /^#/ { next }
    k != "" && $2 != k { next }
    t != "" && $3 != t { next }
    { print }
  ' "$II_LEDGER"
}

# ledger_owned_paths — echo every recorded owned path, one per line, de-split
# from the comma-separated owned_paths column and de-duplicated (first-seen
# order). The reverse-replay engine (#4) consumes this to know which
# distro-owned files to remove.
ledger_owned_paths() {
  [[ -f "$II_LEDGER" ]] || return 0
  awk -F'\t' '
    /^#/ { next }
    NF >= 5 && $5 != "" {
      n = split($5, a, ",")
      for (i = 1; i <= n; i++)
        if (a[i] != "" && !(a[i] in seen)) { seen[a[i]] = 1; print a[i] }
    }
  ' "$II_LEDGER"
}
