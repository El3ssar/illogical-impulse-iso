# shellcheck shell=bash
# common.sh — shared environment for every pipeline script. Source, don't run.
#
# Provides: repo path variables, distro.toml accessors (tget), logging
# helpers (step/ok/warn/info/die), require(), _wipe().

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/scripts"
DOTS="$ROOT/upstream/illogical-impulse"
OVERLAY="$ROOT/overlay"
PACKAGES="$ROOT/packages"
PROFILES="$ROOT/profiles"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
OUT="$ROOT/out"

tget() { "$SCRIPTS/lib/toml-get" "$ROOT/distro.toml" "$@"; }

DISTRO_ID="$(tget distro.id)"
DISTRO_NAME="$(tget distro.name)"
ISO_VERSION="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
WORKDIR="${WORKDIR:-$(tget iso.workdir)}"
REPO_NAME="$(tget repo.name)"
REPO_PATH="$(tget repo.path)"
REPO_DB="$REPO_PATH/$REPO_NAME.db.tar.gz"

if [[ -t 2 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_D=$'\e[2m' C_0=$'\e[0m'
else
  C_R= C_G= C_Y= C_B= C_D= C_0=
fi
step() { printf '\n%s>>%s %s\n'    "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '   %sok%s   %s\n'  "$C_G" "$C_0" "$*" >&2; }
warn() { printf '   %swarn%s %s\n'  "$C_Y" "$C_0" "$*" >&2; }
info() { printf '   %s..%s   %s\n'  "$C_D" "$C_0" "$*" >&2; }
die()  { printf '   %sFAIL%s %s\n'  "$C_R" "$C_0" "$*" >&2; exit 1; }
require() { local c; for c in "$@"; do command -v "$c" >/dev/null || die "missing: $c"; done; }

_wipe() {
  [[ -d "$1" ]] || return 0
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null || sudo rm -rf "$1"
}
