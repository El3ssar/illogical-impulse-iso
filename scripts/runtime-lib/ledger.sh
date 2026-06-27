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
# A literal comma inside a single owned path would otherwise be read as the list
# delimiter and split that path into bogus fragments at revert time, so each path
# in owned_paths is COMMA-ESCAPED at write time (ledger_escape_path) and DECODED
# at read/split time (ledger_unescape_path). owned_paths is the only comma-joined
# column, so it is the only field that needs it.
#
# Concurrency (REV-05): ledger_record (append) and revert-all's read-replay-
# rewrite race — a row appended between revert-all's snapshot and its rewrite
# would be silently dropped and become permanently unrevertable. Both serialize
# on a sidecar lock (II_LEDGER_LOCK) via flock(1) (util-linux, always present).
# The lock is a SEPARATE file from the ledger so revert-all's atomic
# replace-the-file rewrite cannot pull the lock out from under a waiter.
#
# No-op-safe by contract: a plugin must NEVER die because the ledger could not be
# written, so write paths return 0 even when the state dir is unwritable.

II_LEDGER_DIR="${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/illogical-impulse"
II_LEDGER="$II_LEDGER_DIR/ledger.tsv"
# Sidecar advisory lock — serializes ledger_record vs revert-all (REV-05). A
# separate inode from II_LEDGER so the rewrite (replace-the-file) keeps the lock.
II_LEDGER_LOCK="$II_LEDGER_DIR/ledger.lock"

# _ledger_init — ensure the state dir, the ledger file (with a header comment),
# and the sidecar lock file exist. Returns non-zero if the dir is unwritable so
# callers can no-op.
_ledger_init() {
  mkdir -p "$II_LEDGER_DIR" 2>/dev/null || return 1
  [[ -e "$II_LEDGER_LOCK" ]] || : > "$II_LEDGER_LOCK" 2>/dev/null || true
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

# ledger_escape_path <path> — percent-encode the characters that would corrupt
# the owned_paths column: '%' first (so the scheme round-trips), then ',' (the
# list delimiter). The result is comma-free, so comma-joining many of these is
# unambiguous. Pure bash — no sed/tr dependency.
ledger_escape_path() {
  local s="${1:-}"
  s="${s//%/%25}"; s="${s//,/%2C}"
  printf '%s' "$s"
}

# ledger_unescape_path <encoded> — inverse of ledger_escape_path. Decode ',' then
# '%' last (mirror of the encode order) so a literal "%2C" in the original path
# survives the round trip.
ledger_unescape_path() {
  local s="${1:-}"
  s="${s//%2C/,}"; s="${s//%25/%}"
  printf '%s' "$s"
}

# ledger_record <kind> <target> [packages] [owned_paths] [restore_hint]
# Append one row (append-only — never rewrites). owned_paths is a comma-joined
# list of ALREADY-comma-ESCAPED paths (callers must run each path through
# ledger_escape_path before joining; the mutators do). No-op-safe: a missing kind
# or an unwritable state dir returns 0 rather than aborting the caller. The
# append is flock-serialized against revert-all's read-replay-rewrite so a
# concurrent record can never be lost (REV-05).
ledger_record() {
  local kind="${1:-}" target="${2:-}" packages="${3:-}" owned_paths="${4:-}" hint="${5:-}"
  [[ -n "$kind" ]] || return 0
  _ledger_init || return 0
  kind="$(_ledger_sanitize "$kind")"
  target="$(_ledger_sanitize "$target")"
  packages="$(_ledger_sanitize "$packages")"
  owned_paths="$(_ledger_sanitize "$owned_paths")"
  hint="$(_ledger_sanitize "$hint")"
  # Serialize the append under the sidecar lock (flock). The redirect inside the
  # subshell holds the exclusive lock for exactly the append; if flock is somehow
  # missing the append still happens (>> is atomic for short lines) — never die.
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9 || exit 0
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%FT%TZ)" "$kind" "$target" "$packages" "$owned_paths" "$hint" \
        >> "$II_LEDGER" 2>/dev/null || exit 0
    ) 9>"$II_LEDGER_LOCK" 2>/dev/null || return 0
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" "$kind" "$target" "$packages" "$owned_paths" "$hint" \
      >> "$II_LEDGER" 2>/dev/null || return 0
  fi
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
# from the comma-separated owned_paths column, COMMA-UNESCAPED, and de-duplicated
# (first-seen order). The reverse-replay engine (#4) consumes this to know which
# distro-owned files to remove. Awk extracts the raw (still-escaped) tokens; the
# bash loop decodes each via ledger_unescape_path so a path that contained a
# comma is reassembled intact.
ledger_owned_paths() {
  [[ -f "$II_LEDGER" ]] || return 0
  local tok dec
  declare -A _seen=()
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    dec="$(ledger_unescape_path "$tok")"
    [[ -n "${_seen[$dec]:-}" ]] && continue
    _seen["$dec"]=1
    printf '%s\n' "$dec"
  done < <(awk -F'\t' '
    /^#/ { next }
    NF >= 5 && $5 != "" {
      n = split($5, a, ",")
      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    }
  ' "$II_LEDGER")
}
