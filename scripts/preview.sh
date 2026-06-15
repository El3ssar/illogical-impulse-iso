#!/usr/bin/env bash
# preview — launch a standalone Illogical Impulse Quickshell app for a live,
# hot-reloading UI preview, straight from the source tree. No build, no
# install: it just `qs -p`s the app dir; edit the app's shell.qml and
# Quickshell reloads it in place.
#
#   preview            list the available apps
#   preview <app>      launch overlay/airootfs/usr/share/illogical-impulse/<app>
#
# Apps are auto-discovered by the standalone convention — any
# overlay/airootfs/usr/share/illogical-impulse/<app>/shell.qml — so new apps
# (Control Center, app-dashboard, widgets …) appear here automatically as
# they land. Buttons that shell out to `iictl` run against THIS machine, so
# this is for look/feel/layout/logic; exercise the actions in `just nspawn`.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APPS_DIR="$OVERLAY/airootfs/usr/share/illogical-impulse"

# discover apps: <app>/shell.qml directly under APPS_DIR
mapfile -t _apps < <(
  find "$APPS_DIR" -mindepth 2 -maxdepth 2 -name shell.qml -printf '%h\n' 2>/dev/null \
    | sed "s|^$APPS_DIR/||" | sort
)

_list() {
  if (( ${#_apps[@]} == 0 )); then
    warn "no Quickshell apps found under ${APPS_DIR#"$ROOT"/}"
    return
  fi
  step "available apps — run: just preview <app>"
  local a
  for a in "${_apps[@]}"; do printf '   %s\n' "$a" >&2; done
}

APP="${1:-}"
if [[ -z "$APP" ]]; then
  _list
  exit 0
fi

require qs
TARGET="$APPS_DIR/$APP"
if [[ ! -f "$TARGET/shell.qml" ]]; then
  warn "no app named '$APP'"
  _list
  die "unknown app: $APP"
fi

step "qs -p ${TARGET#"$ROOT"/}   (edit shell.qml to hot-reload; Ctrl+C to quit)"
exec qs -p "$TARGET"
