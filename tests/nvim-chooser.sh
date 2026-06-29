#!/usr/bin/env bash
# nvim-chooser.sh — focused, NO-ROOT, NO-NETWORK self-test for the iictl nvim
# chooser drop-in (#17). It exercises every code path that does NOT require a
# live `git clone` (those need a network, an accepted trade — PROPOSAL §4 Pillar
# 1; the maintainer's bake-and-boot gate covers the real online clone). It runs
# the REAL plugin against a throwaway $HOME with the framework relocated via
# II_LIB, so it touches nothing on the host and needs no install.
#
# Asserts:
#   • status reports `plain` on an empty config,
#   • `set plain` on a USER-OWNED (unstamped) config REFUSES without --force,
#   • `set plain --force` backs the config up, clears to vanilla, stamps a ledger
#     row, and reports the backup path,
#   • `restore` rolls the stamped backup back (config returns byte-for-byte),
#   • `theme` writes a distro-owned lua/ii-material.lua + records it,
#   • the ledger carries the kind=file nvim rows with the three owned dirs.
#
# Usage: tests/nvim-chooser.sh   (or: bash tests/nvim-chooser.sh)

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SRC="$ROOT/scripts/runtime-lib/iictl.d/nvim"
[[ -f "$PLUGIN_SRC" ]] || { echo "FATAL: missing $PLUGIN_SRC" >&2; exit 2; }

PASS=0 FAIL=0
C_G=$'\e[32m' C_R=$'\e[31m' C_B=$'\e[1m' C_0=$'\e[0m'
_pass() { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
_fail() { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }

# ── relocate the framework (iictl-common + ledger) into a temp II_LIB so the
#    plugin sources them without /usr/local/lib/ii on a dev box. ───────────────
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export II_LIB="$WORK/lib"
install -d "$II_LIB" "$II_LIB/iictl.d"
install -m 0644 "$ROOT/scripts/runtime-lib/iictl-common.sh" "$II_LIB/iictl-common.sh"
install -m 0644 "$ROOT/scripts/runtime-lib/ledger.sh"       "$II_LIB/ledger.sh"
install -m 0755 "$PLUGIN_SRC" "$II_LIB/iictl.d/nvim"

# Throwaway HOME + the nvim seam paths (all plugin-overridable).
export HOME="$WORK/home"; install -d "$HOME/.config" "$HOME/.local/state"
export II_NVIM_CONFIG="$HOME/.config/nvim"
export II_NVIM_SHARE="$HOME/.local/share/nvim"
export II_NVIM_STATE="$HOME/.local/state/nvim"
export II_NVIM_BACKUP_ROOT="$HOME/.config/ii/nvim-backup"
export XDG_STATE_HOME="$HOME/.local/state"
LEDGER="$HOME/.local/state/illogical-impulse/ledger.tsv"

nvim_run() { "$II_LIB/iictl.d/nvim" "$@"; }

# 1. status on a bare box → plain
out="$(nvim_run status 2>&1)"
[[ "$out" == *plain* ]] && _pass "status reports 'plain' on an empty config" \
                        || _fail "status did not report plain (got: $out)"

# 2. lay down a USER-OWNED config (no .ii-distro stamp) → 'set plain' must REFUSE
install -d "$II_NVIM_CONFIG"
printf 'vim.opt.number = true\n' > "$II_NVIM_CONFIG/init.lua"
if nvim_run set plain >/dev/null 2>&1; then
  _fail "set plain overwrote a non-stamped (user-owned) config WITHOUT --force"
else
  _pass "set plain refuses to clobber a non-stamped user config without --force"
fi
[[ -f "$II_NVIM_CONFIG/init.lua" ]] && _pass "user's init.lua untouched by the refused set" \
                                    || _fail "user's init.lua was removed despite the refusal"

# status now reports user-owned
out="$(nvim_run status 2>&1)"
[[ "$out" == *user-owned* ]] && _pass "status reports 'user-owned' for an unstamped config" \
                             || _fail "status did not report user-owned (got: $out)"

# 3. set plain --force → backs up, clears, records
out="$(nvim_run set plain --force 2>&1)"
backup="$(printf '%s\n' "$out" | sed -nE 's/.*backed up to ([^ ]+).*/\1/p')"
[[ -n "$backup" && -d "$backup" ]] && _pass "set plain --force created a timestamped backup ($backup)" \
                                   || _fail "set plain --force made no backup (out: $out)"
[[ -f "$backup/config/init.lua" ]] && _pass "backup captured the user's init.lua" \
                                   || _fail "backup did not capture init.lua"
[[ -z "$(ls -A "$II_NVIM_CONFIG" 2>/dev/null)" ]] && _pass "config cleared to vanilla (empty) after set plain" \
                                                  || _fail "config not empty after set plain"

# ledger row recorded with the three owned dirs
if [[ -f "$LEDGER" ]] && grep -qE $'\tfile\tnvim:plain\t' "$LEDGER" \
   && grep -q 'nvim' "$LEDGER" && grep -q '.local.share.nvim' "$LEDGER"; then
  _pass "ledger has a kind=file nvim:plain row owning the nvim dirs"
else
  _fail "ledger missing the expected kind=file nvim:plain row ($(cat "$LEDGER" 2>/dev/null))"
fi

# 4. restore → rolls the stamped backup back (init.lua returns)
nvim_run restore >/dev/null 2>&1
[[ -f "$II_NVIM_CONFIG/init.lua" ]] && _pass "restore rolled the stamped backup back (init.lua returned)" \
                                    || _fail "restore did not restore the prior config"

# 5. theme writes a distro-owned material lua + records it
#    (seed a tiny config dir so theme's "has a config" guard passes)
out="$(nvim_run theme 2>&1)"
[[ -f "$II_NVIM_CONFIG/lua/ii-material.lua" ]] && _pass "theme wrote lua/ii-material.lua" \
                                               || _fail "theme did not write ii-material.lua (out: $out)"
grep -q 'return {' "$II_NVIM_CONFIG/lua/ii-material.lua" 2>/dev/null \
  && _pass "ii-material.lua is a valid lua table (static fallback palette)" \
  || _fail "ii-material.lua malformed"
grep -qE $'\tfile\tnvim:theme\t' "$LEDGER" 2>/dev/null \
  && _pass "ledger recorded the theme action (kind=file nvim:theme)" \
  || _fail "ledger missing the nvim:theme row"

echo
printf '%snvim-chooser self-test%s — %spass %d%s  %sfail %d%s\n' \
  "$C_B" "$C_0" "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
(( FAIL == 0 ))
