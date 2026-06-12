#!/usr/bin/env bash
# prepare — assemble the mkarchiso profile in build/.
#
# Usage: prepare.sh [profile]      (or PROFILE=<name> prepare.sh)
#
# The actual work lives in scripts/prepare.d/NN-*.sh, sourced in order.
# Each step is single-purpose so the blast radius of an edit stays small:
#   10-releng     archiso releng baseline (from the installed archiso pkg)
#   20-airootfs   overlay/airootfs + runtime scripts + chroot hook
#   30-skel       skel-upstream / skel / skel-live layer cake (+ profile)
#   40-packages   packages.x86_64 from upstream deps + our manifests
#   50-calamares  installer config + branding
#   60-boot       efiboot menu + profiledef.sh from distro.toml
#   70-assets     generated os-release, release stamp, default wallpaper

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROFILE="${1:-${PROFILE:-}}"
if [[ -n "$PROFILE" && ! -d "$PROFILES/$PROFILE" ]]; then
  die "unknown profile '$PROFILE' — expected $PROFILES/$PROFILE/"
fi
export PROFILE

require rsync git python3 pacman
[[ -d "$DOTS/dots" ]] || die "$DOTS/dots missing — run: just setup"

for _stepfile in "$SCRIPTS/prepare.d/"[0-9]*.sh; do
  # shellcheck disable=SC1090
  source "$_stepfile"
done

step "summary"
printf '   profile          %s\n' "${PROFILE:-(none — public distro)}" >&2
printf '   profiledef.sh    %s bytes\n' "$(stat -c %s "$BUILD/profiledef.sh")" >&2
printf '   packages.x86_64  %s\n'       "$(grep -Ecv '^\s*(#|$)' "$BUILD/packages.x86_64")" >&2
printf '   airootfs/        %s files\n' "$(find "$BUILD/airootfs" -type f | wc -l)" >&2
printf '   efiboot entries  %s\n'       "$(ls "$BUILD/efiboot/loader/entries/" | wc -l)" >&2
ok "build/ ready"
