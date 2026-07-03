# iictl-common.sh — shared header for iictl and every iictl.d/ plugin.
#
# Staged to /usr/local/lib/ii/iictl-common.sh (a survive-path — #1). Sourced once
# by /usr/local/bin/iictl AND by each /usr/local/lib/ii/iictl.d/<cmd> plugin, so
# colors, the ok/bad/warn/die helpers, RELEASE_FILE, _not_root, and the ledger_*
# reversibility helpers exist in exactly one place. set -u-safe and
# side-effect-free on source (defines functions + constants only).
#
# iictl.d/ plugin contract — each plugin is a standalone executable that:
#   - starts with a #! shebang and passes `bash -n`,
#   - carries one header line  "#help: <verb><TAB><one-line>"  (harvested by
#     `iictl help`; a literal tab or spaces both parse),
#   - sources this header near the top:
#       source "${II_LIB:-/usr/local/lib/ii}/iictl-common.sh"
#   - records any reversible system change with ledger_record so `iictl
#     revert-all` (a later issue) can undo it.
#
# II_LIB defaults to the canonical survive-path /usr/local/lib/ii; it is only
# overridden to relocate the whole framework for tests (no root, no chroot).

II_LIB="${II_LIB:-/usr/local/lib/ii}"

# Colours are cosmetic: emit them only to a real terminal and honour NO_COLOR
# (https://no-color.org). Piped/captured output — the Control Center's Ctl reads
# (`iictl version`/`doctor`), the in-window action consoles, and install logs —
# then gets clean, ANSI-free text instead of raw ESC sequences (#14).
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_G='' C_R='' C_Y='' C_B='' C_0=''
fi
ok()   { echo "  ${C_G}ok${C_0}   $*"; }
bad()  { echo "  ${C_R}FAIL${C_0} $*"; }
warn() { echo "  ${C_Y}warn${C_0} $*"; }
die()  { echo "${C_R}error:${C_0} $*" >&2; exit 1; }

RELEASE_FILE=/etc/illogical-impulse/release
_not_root() { [[ $EUID -ne 0 ]] || die "run as your user, not root (sudo is used where needed)"; }

# Ledger helpers (reversibility manifest). Optional source so a dev checkout
# without the staged tree still works; plugins may call ledger_record blindly.
[[ -r "$II_LIB/ledger.sh" ]] && source "$II_LIB/ledger.sh"
