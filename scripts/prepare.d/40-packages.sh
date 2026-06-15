# shellcheck shell=bash disable=SC2154
# 40-packages — produce packages.x86_64 from four channels:
#
#   1. releng baseline           (already in place from 10-releng)
#   2. upstream PKGBUILD depends (scraped by tools/resolve-deps.py — never hand-listed)
#   3. distro manifests          packages/{base,installer,goodies}.list
#   4. profile manifest          profiles/$PROFILE/packages.list (profile builds only)
#
# Names not in the official repos are accumulated into
# .pkg-resolve/aur-prebuild.list for prebuild.sh. packages/optional/*.list
# are NOT baked here — they are curated name-lists installed on demand from the
# internet by `iictl pack` (official repos + AUR; see PROPOSAL §4 Pillar 1 /
# packages/optional). Only the list ships, never the packages. The Calamares
# software-selection screen was built, hit friction, and was removed.

RESOLVE="$BUILD/.pkg-resolve"
PKGLIST="$BUILD/packages.x86_64"

step "resolve upstream PKGBUILD depends"
install -d "$RESOLVE"
python3 "$TOOLS/resolve-deps.py" "$DOTS" "$RESOLVE" >&2

declare -A seen=()
while IFS= read -r p; do [[ -n "$p" ]] && seen["$p"]=1; done \
  < <(grep -Ev '^\s*(#|$)' "$PKGLIST")
# releng ships the -nox flavor; upstream deps want the full one — count it seen.
[[ -n "${seen[virtualbox-guest-utils-nox]:-}" ]] && seen["virtualbox-guest-utils"]=1

_append() {
  local label="$1"; shift
  local -a kept=()
  local p
  for p in "$@"; do
    [[ -n "$p" && -z "${seen[$p]:-}" ]] && { kept+=("$p"); seen["$p"]=1; }
  done
  if (( ${#kept[@]} > 0 )); then
    { echo ""; echo "# $label"; printf '%s\n' "${kept[@]}"; } >> "$PKGLIST"
  fi
}

_add_aur_prebuild() {
  (( $# > 0 )) || return 0
  { cat "$RESOLVE/aur-prebuild.list" 2>/dev/null || true; printf '%s\n' "$@"; } \
    | awk 'NF && !seen[$0]++' > "$RESOLVE/aur-prebuild.list.new"
  mv "$RESOLVE/aur-prebuild.list.new" "$RESOLVE/aur-prebuild.list"
}

# Classify a manifest against the sync db: official → packages.x86_64
# directly, everything else → packages.x86_64 + the prebuild list.
_append_manifest() {
  local label="$1" file="$2"
  [[ -f "$file" ]] || { info "$label: no manifest"; return 0; }
  local -a official=() aur=()
  local pkg
  while IFS= read -r pkg; do
    pkg="${pkg%%#*}"; pkg="${pkg//[[:space:]]/}"
    [[ -n "$pkg" ]] || continue
    if pacman -Si "$pkg" &>/dev/null; then official+=("$pkg"); else aur+=("$pkg"); fi
  done < "$file"
  _append "$label"       "${official[@]}"
  _append "$label (AUR)" "${aur[@]}"
  _add_aur_prebuild "${aur[@]}"
  info "$label: ${#official[@]} official, ${#aur[@]} AUR"
}

step "packages: upstream dots dependencies"
mapfile -t up_off < <(grep -Ev '^\s*$' "$RESOLVE/official.list"     2>/dev/null || true)
mapfile -t up_aur < <(grep -Ev '^\s*$' "$RESOLVE/aur-prebuild.list" 2>/dev/null || true)
_append "illogical-impulse (upstream PKGBUILD depends)" "${up_off[@]}"
_append "illogical-impulse (AUR / local → prebuild)"    "${up_aur[@]}"
ok "${#up_off[@]} official + ${#up_aur[@]} AUR/local"

step "packages: distro manifests"
_append_manifest "distro base"                   "$PACKAGES/base.list"
_append_manifest "installer (purged on install)" "$PACKAGES/installer.list"
_append_manifest "goodies"                       "$PACKAGES/goodies.list"
if [[ -n "$PROFILE" ]]; then
  _append_manifest "profile: $PROFILE" "$PROFILES/$PROFILE/packages.list"
fi
ok "manifests merged"

step "NVIDIA driver manifest (hardware-detected at install — NOT baked)"
# Blindly baking nvidia-utils would blacklist nouveau and break non-NVIDIA
# machines. chroot.sh stashes these as a tiny on-ISO repo; ii-post-install
# detects the GPU and installs the right variant offline.
NV_OFF="$BUILD/airootfs/root/nvidia-official.txt"
NV_AUR="$BUILD/airootfs/root/nvidia-aur.txt"
: > "$NV_OFF"; : > "$NV_AUR"
if [[ -f "$PACKAGES/nvidia.list" ]]; then
  while IFS= read -r _nv_line; do
    _nv_line="${_nv_line%%#*}"
    for p in $_nv_line; do
      if pacman -Si "$p" &>/dev/null; then echo "$p" >> "$NV_OFF"; else echo "$p" >> "$NV_AUR"; fi
    done
  done < "$PACKAGES/nvidia.list"
  mapfile -t _nv_aur_pkgs < <(grep -Ev '^\s*$' "$NV_AUR" || true)
  _add_aur_prebuild "${_nv_aur_pkgs[@]}"
  ok "$(grep -c . "$NV_OFF" || true) official + $(grep -c . "$NV_AUR" || true) AUR"
else
  info "no packages/nvidia.list"
fi

step "cosmetic AUR list for chroot (fail-soft paru pass)"
: > "$BUILD/airootfs/root/aur-packages.txt"
declare -A is_local=()
if [[ -f "$RESOLVE/local-names.list" ]]; then
  while IFS= read -r ln; do [[ -n "$ln" ]] && is_local["$ln"]=1; done < "$RESOLVE/local-names.list"
fi
for p in "${up_aur[@]}"; do
  [[ -z "${is_local[$p]:-}" ]] && echo "$p" >> "$BUILD/airootfs/root/aur-packages.txt"
done

# UEFI-only: BIOS bootloaders pruned (their dirs went away in 10-releng).
sed -i -E '/^(grub|syslinux)\s*$/d' "$PKGLIST"

step "stage overlay/aur-pkgbuilds (local PKGBUILD overrides)"
if [[ -d "$OVERLAY/aur-pkgbuilds" ]]; then
  install -d "$BUILD/aur-pkgbuilds"
  rsync -a "$OVERLAY/aur-pkgbuilds/" "$BUILD/aur-pkgbuilds/"
  ok "$(find "$OVERLAY/aur-pkgbuilds" -name PKGBUILD | wc -l) local PKGBUILD(s)"
else
  info "none"
fi
ok "$(grep -Ecv '^\s*(#|$)' "$PKGLIST") packages total"
