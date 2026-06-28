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

# Precondition: classification below routes every name official-vs-AUR with
# `pacman -Si` against the HOST sync db (also resolve-deps.py upstream). An
# empty/stale db (common on a fresh local checkout — `docked`/CI control it,
# bare local builds don't) makes EVERY official package miss `-Si` and get
# silently misrouted to the AUR/prebuild path: a broken, slow, or failed build
# with no obvious cause. Assert a populated, recent sync db up front and fail
# LOUDLY (telling the maintainer to run `pacman -Sy`) rather than misroute.
# Days a sync db may age before we refuse to trust it; override for odd hosts.
II_SYNCDB_MAX_AGE_DAYS="${II_SYNCDB_MAX_AGE_DAYS:-14}"
_assert_sync_db() {
  step "verify host pacman sync db (official-vs-AUR classification precondition)"
  local dbpath repo db newest=0 mtime now stale_days
  dbpath="$(pacman-conf DBPath 2>/dev/null || echo /var/lib/pacman/)"
  dbpath="${dbpath%/}/sync"
  # Every configured repo EXCEPT our own [ii-extra] (it is built locally, never
  # `pacman -Sy`'d, and its absence/age says nothing about the official db).
  # `pacman-conf --repo-list` is the source of truth; if unavailable, fall back
  # to the on-disk *.db names (still excluding ii-extra).
  local -a repos=()
  if command -v pacman-conf >/dev/null; then
    mapfile -t repos < <(pacman-conf --repo-list 2>/dev/null | grep -vx 'ii-extra' || true)
  else
    mapfile -t repos < <(find "$dbpath" -maxdepth 1 -name '*.db' -printf '%f\n' 2>/dev/null \
                           | sed 's/\.db$//' | grep -vx 'ii-extra' || true)
  fi
  (( ${#repos[@]} > 0 )) || die "no official pacman repos found on this host — cannot classify packages. Run: sudo pacman -Sy (and check /etc/pacman.conf)"
  now="$(date +%s)"
  for repo in "${repos[@]}"; do
    db="$dbpath/$repo.db"
    if [[ ! -s "$db" ]]; then
      die "empty/missing host sync db for [$repo] ($db). Official packages would be misrouted to the AUR. Run: sudo pacman -Sy"
    fi
    mtime="$(stat -c %Y "$db" 2>/dev/null || echo 0)"
    (( mtime > newest )) && newest="$mtime"
  done
  stale_days=$(( (now - newest) / 86400 ))
  if (( newest == 0 || stale_days > II_SYNCDB_MAX_AGE_DAYS )); then
    die "host pacman sync db is stale (${stale_days}d old, max ${II_SYNCDB_MAX_AGE_DAYS}d) — classification may misroute renamed/dropped packages. Run: sudo pacman -Sy (or raise II_SYNCDB_MAX_AGE_DAYS)"
  fi
  ok "${#repos[@]} official sync db(s) present, newest ${stale_days}d old (≤ ${II_SYNCDB_MAX_AGE_DAYS}d)"
}
_assert_sync_db

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
  # `|| [[ -n "$pkg" ]]` keeps a final line with no trailing newline (read
  # returns non-zero at EOF but still populates $pkg) — a maintainer/profile
  # manifest must never silently drop its last package. validate.sh guards the
  # trailing newline too (belt-and-suspenders).
  while IFS= read -r pkg || [[ -n "$pkg" ]]; do
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
  # `|| [[ -n "$_nv_line" ]]` keeps a final no-trailing-newline line — an edited
  # nvidia.list must never silently drop its last driver entry (validate.sh also
  # guards the trailing newline).
  while IFS= read -r _nv_line || [[ -n "$_nv_line" ]]; do
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
  # `|| [[ -n "$ln" ]]` keeps a final line lacking a trailing newline so a local
  # PKGBUILD name on the last line still classifies (skips the cosmetic AUR pass).
  while IFS= read -r ln || [[ -n "$ln" ]]; do [[ -n "$ln" ]] && is_local["$ln"]=1; done < "$RESOLVE/local-names.list"
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
