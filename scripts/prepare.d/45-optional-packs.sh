# shellcheck shell=bash disable=SC2154
# 45-optional-packs — stage the curated optional pack name-lists (+ their #meta
# and the optional <pack>.d/post-add|post-remove hook fragments) into the
# squashfs as TEXT at /usr/share/illogical-impulse/optional/. These are NOT baked
# packages: only the few-KB lists ride in the image; `iictl pack` installs the
# members ONLINE on demand (official repos via pacman, AUR via paru) — PROPOSAL §4
# Pillar 1/7. 40-packages.sh deliberately omits them from packages.x86_64; this
# step makes the engine's catalog available on the installed system. The catalog
# lives under /usr/share (a sibling of the iictl survive-path), untouched by
# ii-verify's /usr/local/lib/ii purge — so `iictl pack` keeps working post-install.

step "optional pack name-lists → /usr/share/illogical-impulse/optional"
_OPTSRC="$PACKAGES/optional"
_OPTDST="$BUILD/airootfs/usr/share/illogical-impulse/optional"
if [[ ! -d "$_OPTSRC" ]]; then
  info "no packages/optional/ — nothing to stage"
else
  install -d "$_OPTDST"
  _opt_n=0
  shopt -s nullglob
  # Lists + metas — the text manifests the engine enumerates (0644).
  for _f in "$_OPTSRC"/*.list "$_OPTSRC"/*.meta; do
    install -Dm 0644 "$_f" "$_OPTDST/$(basename "$_f")"
    _opt_n=$((_opt_n+1))
  done
  # Per-pack hook fragments (<pack>.d/post-add|post-remove). The engine SOURCES
  # them (does not exec), so they ship 0644 — sourcing dodges mkarchiso's +x
  # mode-strip and gives them the ledger/mutator helpers in scope.
  for _hookdir in "$_OPTSRC"/*.d; do
    [[ -d "$_hookdir" ]] || continue
    for _h in "$_hookdir"/*; do
      [[ -f "$_h" ]] || continue
      install -Dm 0644 "$_h" "$_OPTDST/$(basename "$_hookdir")/$(basename "$_h")"
    done
  done
  shopt -u nullglob
  ok "$_opt_n optional pack list(s)/meta staged"
fi
