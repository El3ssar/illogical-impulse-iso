#!/usr/bin/env bash
# ii-theme-feeder.sh — the Material You FEEDER recolour hook (#26 / PROPOSAL §9).
#
# OFF by default. It is baked into the UNOWNED ~/.config/hypr/custom/scripts/
# seam but NOT autostarted until the user opts in with `iictl theme feeder
# enable`, which writes ONE sentinel-fenced line into custom/execs.lua (via the
# shared ii_lua_block_write mutator, ledger-recorded).
#
# What it does: it runs a STANDALONE matugen against upstream's FINISHED colours
# and our SEPARATE config, so tools upstream does not recolour (nvim / extra
# terminals / IDEs) track the rice palette. It is the SINGLE owner of this hook
# (audit fix b): the terminal/TUI/editor domains CONSUME the generated files, they
# do not add a second watcher.
#
#     matugen json <FINISHED colors.json> --config <our distro config>
#
# Iron-Law safety, encoded here:
#   • Reads upstream's colours.json READ-ONLY (upstream runtime STATE — observe,
#     never seed). It NEVER touches upstream's matugen config.toml, gtk.css, or
#     any rsync --delete tree — matugen writes only the output_paths in OUR config
#     (all in the unowned theming namespace / the empty ~/.config/nvim seam).
#   • Debounced: the applycolor.sh race CLAUDE.md §6 warns about is avoided by
#     reading the FINISHED colours.json (not a mid-write .scss) and coalescing
#     bursts, so a rapid wallpaper switch fires matugen once, after it settles.
#
# Modes:
#   --once   render once from the current colours.json, then exit (default).
#   --watch  render once, then watch colours.json and re-render (debounced) on
#            every change — the mode the autostart fence uses.

set -u

# Upstream's FINISHED generated colour map (flat name → hex). Upstream runtime
# STATE — read-only; we only ever READ it. Overridable for a manual test run.
COLORS_JSON="${II_FEEDER_COLORS:-$HOME/.local/state/quickshell/user/generated/colors.json}"
# Our STANDALONE matugen config in the UNOWNED theming namespace (never upstream's).
FEEDER_CONFIG="${II_FEEDER_CONFIG:-$HOME/.config/illogical-impulse-theming/config.toml}"
# Debounce window (seconds) — coalesce a burst of colours.json writes into one run.
DEBOUNCE="${II_FEEDER_DEBOUNCE:-2}"

_log() { printf '[ii-theme-feeder] %s\n' "$*" >&2; }

# _render — one standalone matugen pass. Fail-soft: a missing matugen / config /
# colours.json just skips (never blocks the session, never errors the caller).
_render() {
  command -v matugen >/dev/null 2>&1 || { _log "matugen not found — skipping"; return 0; }
  [[ -f "$FEEDER_CONFIG" ]] || { _log "no feeder config at $FEEDER_CONFIG — skipping"; return 0; }
  [[ -f "$COLORS_JSON"   ]] || { _log "colours.json not generated yet ($COLORS_JSON) — skipping"; return 0; }
  # `matugen json <finished colors.json> --config <ours>` reads the flat name→hex
  # map and renders OUR templates from it — recomputes nothing, touches no
  # upstream-owned path. -q keeps the session log quiet.
  matugen -q json "$COLORS_JSON" --config "$FEEDER_CONFIG" >/dev/null 2>&1 \
    && _log "recoloured extra tools from $COLORS_JSON" \
    || _log "matugen render reported an error (non-fatal)"
}

# _watch — render once, then re-render (debounced) whenever colours.json changes.
# Prefers inotifywait; falls back to an mtime poll so it works without
# inotify-tools (fail-soft — a missing watcher just polls).
_watch() {
  _render
  if command -v inotifywait >/dev/null 2>&1; then
    local dir; dir="$(dirname "$COLORS_JSON")"
    while :; do
      # Block until colours.json (or its dir) is written, then debounce: swallow
      # a burst of follow-up events within the window before the single render.
      inotifywait -q -e close_write -e moved_to -e create "$dir" >/dev/null 2>&1 || sleep "$DEBOUNCE"
      sleep "$DEBOUNCE"
      _render
    done
  else
    _log "inotifywait not found — falling back to a ${DEBOUNCE}s mtime poll"
    local last="" now
    while :; do
      sleep "$DEBOUNCE"
      now="$(stat -c %Y "$COLORS_JSON" 2>/dev/null || echo 0)"
      [[ "$now" != "$last" ]] && { last="$now"; _render; }
    done
  fi
}

case "${1:-once}" in
  --watch|watch) _watch ;;
  --once|once|"") _render ;;
  *) _log "usage: ii-theme-feeder.sh [--once|--watch]"; exit 1 ;;
esac
