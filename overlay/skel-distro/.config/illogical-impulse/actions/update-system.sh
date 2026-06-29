#!/usr/bin/env bash
# Command-palette action: full system update in a terminal.
#
# Auto-discovered by upstream's launcher (LauncherSearch.qml runs every
# ~/.config/illogical-impulse/actions/*.sh with Quickshell.execDetached([path]),
# zero upstream edits). Display name = basename sans extension ("update-system").
# `iictl update --system` needs root + an interactive tty, so we open the rice's
# terminal. Additive + reversible: delete this file → the action is gone.
set -u

# Run <cmd> in a terminal: rice-configured (apps.terminal in config.json), then
# $TERMINAL, then a probe list; kitty/foot take the program directly, others -e.
_run_in_term() {
  local cmd="$1" term="" base t
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
  if command -v jq >/dev/null 2>&1 && [[ -f "$cfg" ]]; then
    term="$(jq -r '.apps.terminal // empty' "$cfg" 2>/dev/null)"
  fi
  [[ -n "$term" ]] || term="${TERMINAL:-}"
  if [[ -n "$term" ]]; then
    # shellcheck disable=SC2086
    set -- $term
    base="$(basename "$1")"
    if command -v "$1" >/dev/null 2>&1; then
      case "$base" in
        kitty|foot) exec "$@" bash -lc "$cmd" ;;
        *)          exec "$@" -e bash -lc "$cmd" ;;
      esac
    fi
  fi
  for t in kitty foot alacritty konsole ghostty xterm; do
    command -v "$t" >/dev/null 2>&1 || continue
    case "$t" in
      kitty|foot) exec "$t" bash -lc "$cmd" ;;
      *)          exec "$t" -e bash -lc "$cmd" ;;
    esac
  done
  command -v notify-send >/dev/null 2>&1 \
    && notify-send "Illogical Impulse" "no terminal found — open one and run: iictl update --system" 2>/dev/null || true
  exec bash -lc "$cmd"
}

_run_in_term "iictl update --system; printf '\n[press enter to close] '; read -r _"
