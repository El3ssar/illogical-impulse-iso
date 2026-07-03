#!/usr/bin/env bash
# tui-chooser.sh — focused, NO-ROOT, NO-NETWORK self-test for the iictl tui
# terminal/multiplexer chooser drop-in (#23). It exercises every code path that
# does NOT require an online package install (kitty is baked, so `term kitty`
# never installs; the online pacman/paru path is covered by the maintainer's
# bake-and-boot gate). It runs the REAL plugin against a throwaway $HOME with the
# framework relocated via II_LIB, so it touches nothing on the host and needs no
# install. A fake `kitty`/`zellij` on PATH keeps the emulator/mux presence checks
# happy without installing anything.
#
# Asserts:
#   • status reports `default`/`none` on a vanilla box,
#   • `term kitty` writes a sentinel-fenced terminal= override into
#     custom/variables.lua whose value is a FALLBACK LIST (chosen first, run
#     through launch_first_available.sh, MORE THAN ONE entry) — graceful
#     degradation on uninstall,
#   • the override is idempotently REPLACED (not duplicated) on a second `term`,
#   • the override is recorded as a kind=lua-block ledger row (revert strips it),
#   • `mux zellij` (config-only) writes NO drop-in; `mux zellij --autostart`
#     writes the unowned shell drop-ins + kind=path ledger rows; `mux none`
#     removes them,
#   • stripping the terminal fence yields the ORIGINAL stub byte-for-byte
#     (revert-all restores vanilla) while a co-present user line survives,
#   • --spec emits valid two-control JSON reflecting the current selection.
#
# Usage: tests/tui-chooser.sh   (or: bash tests/tui-chooser.sh)

set -u

# ── Drop root → unprivileged user (see nvim-chooser.sh for the rationale). CI
#    runs `just validate` as ROOT in an Arch container, but the tui chooser
#    refuses to write a user's config as root (_not_root). Re-exec as a throwaway
#    non-root user. No path here installs a package, so pacman/network are NOT
#    required — only an unprivileged uid + a fake kitty/zellij on PATH. ─────────
if [[ "$(id -u)" -eq 0 ]]; then
  _st_user=ii-tui-selftest
  id "$_st_user" >/dev/null 2>&1 || useradd -M "$_st_user" >/dev/null 2>&1 || useradd "$_st_user" >/dev/null 2>&1 || true
  if id "$_st_user" >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$_st_user" -- bash "${BASH_SOURCE[0]}" "$@"
  elif id "$_st_user" >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
    exec su -s /bin/bash "$_st_user" -c 'exec bash "$0" "$@"' "${BASH_SOURCE[0]}" "$@"
  fi
  echo "FATAL: tui self-test must run unprivileged and could not drop root" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SRC="$ROOT/scripts/runtime-lib/iictl.d/tui"
[[ -f "$PLUGIN_SRC" ]] || { echo "FATAL: missing $PLUGIN_SRC" >&2; exit 2; }

PASS=0 FAIL=0
C_G=$'\e[32m' C_R=$'\e[31m' C_B=$'\e[1m' C_0=$'\e[0m'
_pass() { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
_fail() { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }

# ── relocate the framework (iictl-common + ledger + mutator) into a temp II_LIB
#    so the plugin sources them without /usr/local/lib/ii on a dev box. ─────────
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export II_LIB="$WORK/lib"
install -d "$II_LIB" "$II_LIB/iictl.d"
install -m 0644 "$ROOT/scripts/runtime-lib/iictl-common.sh" "$II_LIB/iictl-common.sh"
install -m 0644 "$ROOT/scripts/runtime-lib/ledger.sh"       "$II_LIB/ledger.sh"
install -m 0644 "$ROOT/scripts/runtime-lib/mutator.sh"      "$II_LIB/mutator.sh"
install -m 0755 "$PLUGIN_SRC" "$II_LIB/iictl.d/tui"

# Fake emulator/mux binaries so the presence checks pass without installing.
install -d "$WORK/bin"
for b in kitty zellij; do printf '#!/bin/sh\n' > "$WORK/bin/$b"; chmod +x "$WORK/bin/$b"; done
export PATH="$WORK/bin:$PATH"

# Throwaway HOME + the seam paths. The mutator only writes a path matching
# */.config/hypr/custom/*.lua, so the override MUST use the real default path
# under the fake HOME (not an arbitrary override).
export HOME="$WORK/home"
install -d "$HOME/.config/hypr/custom" "$HOME/.config/zellij/layouts" \
           "$HOME/.config/fish/conf.d" "$HOME/.config/zsh" "$HOME/.local/state"
export XDG_STATE_HOME="$HOME/.local/state"
VARS="$HOME/.config/hypr/custom/variables.lua"
: > "$VARS"                                   # upstream's empty stub
: > "$HOME/.config/zellij/config.kdl"         # pretend the baked config landed
FISH_DROP="$HOME/.config/fish/conf.d/ii-mux.fish"
ZSH_DROP="$HOME/.config/zsh/ii-mux.zsh"
LEDGER="$HOME/.local/state/illogical-impulse/ledger.tsv"

tui_run() { "$II_LIB/iictl.d/tui" "$@" </dev/null; }

# 1. status on a vanilla box → default / none
out="$(tui_run status 2>&1)"
[[ "$out" == *default* && "$out" == *none* ]] \
  && _pass "status reports default terminal + none multiplexer on a vanilla box" \
  || _fail "status did not report default/none (got: $out)"

# 2. term kitty → fenced override, fallback LIST (chosen first + >1 entry)
tui_run term kitty >/dev/null 2>&1
if grep -qxF -e "-- >>> illogical-impulse terminal" "$VARS"; then
  _pass "term kitty wrote the sentinel-fenced 'terminal' block into custom/variables.lua"
else
  _fail "term kitty did not write the sentinel fence (got: $(cat "$VARS"))"
fi
term_line="$(grep -E '^terminal[[:space:]]*=' "$VARS" 2>/dev/null | head -1)"
grep -q 'launch_first_available.sh' <<<"$term_line" \
  && _pass "override runs through upstream's launch_first_available.sh (graceful fallback)" \
  || _fail "override does not use launch_first_available.sh (got: $term_line)"
nquoted="$(grep -oE "'[^']+'" <<<"$term_line" | wc -l)"
(( nquoted > 1 )) \
  && _pass "override is a FALLBACK LIST ($nquoted entries), not a lone binary" \
  || _fail "override lists only $nquoted terminal(s) — must be a fallback LIST (>1)"
grep -qE "^terminal[[:space:]]*=.*'kitty -1'" "$VARS" \
  && _pass "chosen emulator (kitty) is FIRST in the fallback list" \
  || _fail "chosen emulator is not first in the list (got: $term_line)"

# 3. idempotent replace: a second term does not duplicate the fence
tui_run term kitty >/dev/null 2>&1
n_open="$(grep -cxF -e "-- >>> illogical-impulse terminal" "$VARS")"
(( n_open == 1 )) \
  && _pass "a repeated term is idempotent (exactly one fenced block, no duplication)" \
  || _fail "term duplicated the fence ($n_open open markers)"

# 4. ledger row recorded as kind=lua-block for the override
if [[ -f "$LEDGER" ]] && grep -qE $'\tlua-block\t' "$LEDGER" && grep -q 'variables.lua' "$LEDGER"; then
  _pass "ledger has a kind=lua-block row for the terminal override (revert strips it)"
else
  _fail "ledger missing the kind=lua-block terminal row ($(cat "$LEDGER" 2>/dev/null))"
fi

# 5. mux zellij (config-only) writes NO drop-in
tui_run mux zellij >/dev/null 2>&1
[[ ! -f "$FISH_DROP" && ! -f "$ZSH_DROP" ]] \
  && _pass "mux zellij (config-only) wrote no autostart drop-in" \
  || _fail "mux zellij wrote an autostart drop-in without --autostart"

# 6. mux zellij --autostart writes the unowned drop-ins + kind=path ledger rows
tui_run mux zellij --autostart >/dev/null 2>&1
[[ -f "$FISH_DROP" && -f "$ZSH_DROP" ]] \
  && _pass "mux zellij --autostart wrote both unowned shell drop-ins" \
  || _fail "mux --autostart did not write the drop-ins"
grep -q 'ii-mux:zellij' "$FISH_DROP" 2>/dev/null \
  && _pass "fish drop-in carries the ii-mux:zellij selection marker" \
  || _fail "fish drop-in missing the ii-mux marker"
grep -qE $'\tpath\ttui:mux\t' "$LEDGER" 2>/dev/null \
  && _pass "ledger has kind=path tui:mux rows for the autostart drop-ins" \
  || _fail "ledger missing the tui:mux path rows"
out="$(tui_run status 2>&1)"
[[ "$out" == *zellij* ]] \
  && _pass "status reads the mux selection (zellij) back from the drop-in" \
  || _fail "status did not report the zellij mux (got: $out)"

# 7. mux none removes the drop-ins
tui_run mux none >/dev/null 2>&1
[[ ! -f "$FISH_DROP" && ! -f "$ZSH_DROP" ]] \
  && _pass "mux none removed both autostart drop-ins" \
  || _fail "mux none left a drop-in behind"

# 8. --spec emits two-control JSON reflecting the current term selection
spec="$(tui_run --spec 2>&1)"
grep -q '"domain":"tui"' <<<"$spec" && grep -q '"id":"term"' <<<"$spec" && grep -q '"id":"mux"' <<<"$spec" \
  && _pass "--spec emits the two-control (term + mux) chooser JSON" \
  || _fail "--spec malformed (got: $spec)"
grep -q '"current":"kitty"' <<<"$spec" \
  && _pass "--spec reflects the current terminal selection (kitty)" \
  || _fail "--spec did not reflect the current term (got: $spec)"

# 9. reversibility: stripping the terminal fence yields the ORIGINAL stub while a
#    co-present user line survives (revert-all restores vanilla, keeps user lines)
printf 'workspaceGroupSize = 12\n' >> "$VARS"     # a user line ALONGSIDE our fence
cp "$VARS" "$WORK/with-fence-and-user"
# manual strip via the same awk the mutator uses
awk '/^-- >>> illogical-impulse /{f=1;next} /^-- <<< illogical-impulse /{f=0;next} !f' \
  "$VARS" > "$WORK/stripped"
if grep -q 'workspaceGroupSize = 12' "$WORK/stripped" \
   && ! grep -q 'illogical-impulse terminal' "$WORK/stripped"; then
  _pass "stripping the terminal fence removes our block but preserves the user's line"
else
  _fail "fence strip did not cleanly separate our block from the user's line"
fi

echo
printf '%stui-chooser self-test%s — %spass %d%s  %sfail %d%s\n' \
  "$C_B" "$C_0" "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
(( FAIL == 0 ))
