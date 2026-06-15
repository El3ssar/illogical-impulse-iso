# ledger.sh — append-only TSV state ledger (STUB).
#
# Staged to /usr/local/lib/ii/ledger.sh; sourced by iictl-common.sh (and thus by
# iictl + every iictl.d/ plugin). This is a deliberately minimal stub: it exists
# so the common header and plugins have ledger_* functions to call NOW, and so
# the /usr/local/lib/ii survive-path (#1) is exercised. Full replay/query/dedup
# semantics land in the dedicated ledger issue (#3) — do NOT grow this file into
# that; just fill it in there. Plain TSV, no jq, set -u-safe, side-effect-free on
# source (defines functions + namespaced II_LEDGER* constants only).
#
# Schema (one row per reversible action), tab-separated:
#   ts <TAB> kind <TAB> target <TAB> packages <TAB> owned_paths <TAB> restore_hint
# owned_paths is a comma-separated list; packages is space-separated.

II_LEDGER_DIR="${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/illogical-impulse"
II_LEDGER="$II_LEDGER_DIR/ledger.tsv"

# ledger_record <kind> <target> [packages] [owned_paths] [restore_hint]
# Append one row. No-op-safe: a missing kind or an unwritable state dir returns
# 0 rather than aborting the caller (a plugin must never die because the ledger
# could not be written).
ledger_record() {
  local kind="${1:-}" target="${2:-}" packages="${3:-}" owned_paths="${4:-}" hint="${5:-}"
  [[ -n "$kind" ]] || return 0
  mkdir -p "$II_LEDGER_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$kind" "$target" "$packages" "$owned_paths" "$hint" \
    >> "$II_LEDGER" 2>/dev/null || return 0
}

# ledger_query [kind] — echo matching rows verbatim (all rows if no kind given).
ledger_query() {
  [[ -f "$II_LEDGER" ]] || return 0
  local kind="${1:-}"
  if [[ -n "$kind" ]]; then
    awk -F'\t' -v k="$kind" '$2 == k' "$II_LEDGER"
  else
    cat "$II_LEDGER"
  fi
}

# ledger_owned_paths — echo every recorded owned path, one per line, de-split
# from the comma-separated owned_paths column. The reverse-replay engine (#4)
# consumes this to know which distro-owned files to remove.
ledger_owned_paths() {
  [[ -f "$II_LEDGER" ]] || return 0
  awk -F'\t' 'NF >= 5 && $5 != "" {
    n = split($5, a, ",")
    for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
  }' "$II_LEDGER"
}
