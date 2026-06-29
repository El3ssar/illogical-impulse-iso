#!/usr/bin/env bash
# ii-theme-recolor.sh — OPT-IN, OFF-BY-DEFAULT debounced extra-tool recolour
# watcher (Illogical Impulse ISO addition, issue #16).
#
# This script is BAKED into the installed user's skel under the UNOWNED
# ~/.config/hypr/custom/scripts/ path (upstream ships nothing here), but it is
# NOT autostarted by default. `iictl theme watch enable` writes a single
# sentinel-fenced block into ~/.config/hypr/custom/execs.lua that runs us with
# `--watch`; `iictl theme watch disable` (or `iictl revert-all`) strips it.
#
# It is the SINGLE owner of the recolour hook (the terminal/TUI work in #23
# CONSUMES this, it must NOT add a second watcher).
#
# Strictly READ-ONLY of upstream state: it watches the FINISHED generated colour
# file ~/.local/state/quickshell/user/generated/colors.json (NOT the mid-write
# material_colors.scss) and re-renders ONLY the static, distro-owned, UNOWNED
# tool configs under ~/.config/{btop,bat,...}. It NEVER writes an upstream-owned
# path (matugen, quickshell/ii, the generated/ STATE dir) — deleting this file
# and the fenced exec block returns the system to vanilla.
#
# Best-effort and dependency-light: if jq or inotifywait is missing it degrades
# (a one-shot apply / a polling loop) rather than failing the session.

set -u

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated"
COLORS_JSON="$STATE/colors.json"
DEBOUNCE="${II_RECOLOR_DEBOUNCE:-1}"   # seconds to coalesce a burst of writes
TAG="ii-theme-recolor"

log() { printf '%s %s\n' "$TAG:" "$*" >&2; }

# _color <role> — echo the hex for a Material role from the FINISHED colors.json
# (e.g. primary, surface, onSurface). Empty if jq/file/key is unavailable. We
# read the finished file only; we never write it.
_color() {
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$COLORS_JSON" ]] || return 0
  local v; v="$(jq -r --arg k "$1" '.[$k] // .colors[$k] // empty' "$COLORS_JSON" 2>/dev/null)"
  [[ -n "$v" && "$v" != null ]] && printf '%s' "$v"
}

# render — re-derive the distro-owned extra-tool themes from the current
# colours. This issue (#16) ships the static cold-start defaults; the live
# re-render writes ONLY into distro-owned/unowned config paths. Each tool block
# is guarded so a tool the user removed never breaks the loop. Extend per tool;
# the terminal/TUI renderer (#23) hangs off this same hook.
render() {
  local primary surface on_surface
  primary="$(_color primary)"
  surface="$(_color surface)"
  on_surface="$(_color onSurface)"
  [[ -n "$primary" ]] || { log "no finished colours yet ($COLORS_JSON) — skipping"; return 0; }

  # btop: rewrite the [theme] accent in the distro-owned theme file (UNOWNED by
  # upstream). Only touches ~/.config/btop/themes/ii.theme — never an upstream path.
  local btop_theme="$HOME/.config/btop/themes/ii.theme"
  if [[ -f "$btop_theme" ]]; then
    sed -i -E "s|^(theme\[main_fg\]=).*|\1\"$on_surface\"|; s|^(theme\[hi_fg\]=).*|\1\"$primary\"|; s|^(theme\[selected_bg\]=).*|\1\"$primary\"|" \
      "$btop_theme" 2>/dev/null || true
    log "re-rendered btop theme (primary=$primary)"
  fi

  # Future extra-tool renderers (bat/lazygit/fastfetch live recolour, and the
  # #23 terminal set) hang here — each writing only its own UNOWNED config path.
}

watch_loop() {
  render   # apply once on start so colours are right immediately
  if command -v inotifywait >/dev/null 2>&1; then
    log "watching $COLORS_JSON (inotify, debounce ${DEBOUNCE}s)"
    while inotifywait -qq -e close_write -e moved_to "$(dirname "$COLORS_JSON")" 2>/dev/null; do
      # debounce: coalesce a burst (matugen rewrites several files at once)
      sleep "$DEBOUNCE"
      render
    done
  else
    # Fallback: cheap mtime poll so the watcher still works without inotify-tools.
    log "inotifywait missing — polling $COLORS_JSON every 5s"
    local last="" cur
    while :; do
      cur="$(stat -c %Y "$COLORS_JSON" 2>/dev/null || echo 0)"
      [[ "$cur" != "$last" ]] && { last="$cur"; render; }
      sleep 5
    done
  fi
}

case "${1:-once}" in
  --watch|watch) watch_loop ;;
  --once|once)   render ;;
  *)             render ;;
esac
