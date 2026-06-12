#!/usr/bin/env bash
# prebuild — build AUR/local PKGBUILDs into the local [ii-extra] pacman repo
# that mkarchiso pulls from during pacstrap.
#
# Per-package cache decision:
#   *-git           → always rebuild
#   local PKGBUILD  → source it, compare pkgver-pkgrel to cached filename
#   plain AUR       → query AUR RPC, compare Version to cached filename
#   match           → skip
#   mismatch/none   → makepkg into staging, wipe stale, swap in (atomic)
#   RPC failure     → trust cache (don't rebuild on transient network errors)
#
# The cache wipe happens AFTER a successful makepkg, so a build failure
# leaves the previous version intact for the next mkarchiso run.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[[ $EUID -eq 0 ]] && die "prebuild must NOT run as root (makepkg refuses)"
require makepkg repo-add git curl sudo python3
[[ -f "$BUILD/.pkg-resolve/aur-prebuild.list" ]] || die "no $BUILD/.pkg-resolve/ — just prepare first"

_is_git() { [[ "$1" == *-git ]]; }

# -git packages always rebuild by policy — but not twice in one sitting.
# A cached artifact younger than GIT_FRESH_HOURS lets a rerun after a
# transient failure elsewhere skip the recompile (quickshell-git is heavy).
GIT_FRESH_HOURS="${GIT_FRESH_HOURS:-6}"
_fresh_git_cache() {
  local pkg="$1" f
  f=$(ls -t "$REPO_PATH/$pkg-"*.pkg.tar.* 2>/dev/null | grep -v -- '-debug-' | head -1) || true
  [[ -n "$f" ]] || return 1
  (( $(date +%s) - $(stat -c %Y "$f") < GIT_FRESH_HOURS * 3600 ))
}

_local_dir() {
  local pkg="$1" d
  for d in "$BUILD/aur-pkgbuilds/$pkg" "$OVERLAY/aur-pkgbuilds/$pkg"; do
    [[ -f "$d/PKGBUILD" ]] && { echo "$d"; return 0; }
  done
  return 1
}

_pkgbuild_ver() {
  [[ -f "$1" ]] || return 1
  ( set +u
    unset epoch pkgver pkgrel
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1 || exit 1
    [[ -n "$pkgver" && -n "$pkgrel" ]] || exit 1
    printf '%s%s-%s' "${epoch:+$epoch:}" "$pkgver" "$pkgrel"
  )
}

_aur_ver() {
  local j
  j=$(curl -fsS --max-time 5 "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$1") || return 1
  python3 -c '
import json, sys
r = json.loads(sys.argv[1]).get("results") or []
if not r: sys.exit(1)
v = r[0].get("Version", "")
if not v: sys.exit(1)
print(v)
' "$j" 2>/dev/null
}

_aur_base() {
  local j
  j=$(curl -fsS --max-time 5 "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$1") || return 1
  python3 -c '
import json, sys
r = json.loads(sys.argv[1]).get("results") or []
if not r or not r[0].get("PackageBase"): sys.exit(1)
print(r[0]["PackageBase"])
' "$j" 2>/dev/null
}

_cached_ver() {
  local pkg="$1" f b rest
  shopt -s nullglob
  for f in "$REPO_PATH/$pkg-"*.pkg.tar.*; do
    [[ "$f" == *-debug-* ]] && continue
    b="${f##*/}"; rest="${b#"$pkg"-}"; rest="${rest%-*.pkg.tar.*}"
    shopt -u nullglob
    echo "$rest"; return 0
  done
  shopt -u nullglob
  return 1
}

_current_ver() {
  local pkg="$1" d
  if d=$(_local_dir "$pkg"); then
    _pkgbuild_ver "$d/PKGBUILD" || true
  else
    _aur_ver "$pkg" || true
  fi
}

# Build a PKGBUILD dir into staging; on success, atomically swap into the cache.
# Args: src_dir, label, pkgname
_build() {
  local src="$1" label="$2" pkg="$3"
  local dest="$WORK/$pkg-$RANDOM"
  cp -r "$src" "$dest"
  # One retry: source downloads regularly hit transient resets (GitHub raw).
  # The retry adds -C (clean srcdir) — PKGBUILDs with self-extracting
  # sources (nvidia .run) refuse to extract over a half-done src/ tree.
  ( cd "$dest" && makepkg -sf --noconfirm --skippgpcheck ) \
    || { warn "makepkg failed for $label — retrying once (clean build)"
         ( cd "$dest" && makepkg -sfC --noconfirm --skippgpcheck ); } \
    || die "makepkg failed: $label"
  shopt -s nullglob
  local built=( "$dest"/*.pkg.tar.* )
  shopt -u nullglob
  # Build succeeded — stage EVERY split-package artifact, not just $pkg:
  # one pkgbase can satisfy several required names (nvidia-580xx-dkms and
  # nvidia-580xx-utils share a base; staging both makes the sibling hit
  # the version-match skip instead of recompiling the whole thing).
  local b base name staged=0 have_pkg=0
  for b in "${built[@]}"; do
    base="${b##*/}"
    [[ "$base" == *-debug-* ]] && continue
    name="${base%-*-*-*}"   # strip pkgver-pkgrel-arch.pkg.tar.*
    sudo rm -f "$REPO_PATH/$name-"*.pkg.tar.*
    sudo mv "$b" "$REPO_PATH/"
    info "staged $base"
    staged=$((staged + 1))
    [[ "$name" == "$pkg" ]] && have_pkg=1
  done
  (( staged > 0 ))   || die "no artifacts in build output for $label"
  (( have_pkg > 0 )) || die "build of $label produced no $pkg package"
}

mapfile -t REQUIRED < <(grep -Ev '^\s*$' "$BUILD/.pkg-resolve/aur-prebuild.list")
mapfile -t LOCAL_PKG_DIRS < <(grep -Ev '^\s*$' "$BUILD/.pkg-resolve/local-dirs.list" 2>/dev/null || true)
declare -A IS_LOCAL=()
for d in "${LOCAL_PKG_DIRS[@]}"; do IS_LOCAL["$(basename "$d")"]=1; done

# qt6-avif-image-plugin + calamares first — others depend on them.
declare -a ORDER=()
declare -A SEEN=()
for p in qt6-avif-image-plugin calamares; do
  for pkg in "${REQUIRED[@]}"; do
    [[ "$pkg" == "$p" && -z "${SEEN[$pkg]:-}" ]] && { ORDER+=("$pkg"); SEEN["$pkg"]=1; }
  done
done
for pkg in "${REQUIRED[@]}"; do
  [[ -z "${IS_LOCAL[$pkg]:-}" && -z "${SEEN[$pkg]:-}" ]] && { ORDER+=("$pkg"); SEEN["$pkg"]=1; }
done

# Prompt for sudo up-front rather than mid-loop where the error is invisible.
step "checking sudo (for [$REPO_NAME] cache writes)"
sudo -v || die "sudo refused — prebuild needs to write to $REPO_PATH"

sudo install -d -m 0755 -o root -g root "$REPO_PATH"
# Scratch on DISK, not /tmp: /tmp is tmpfs with per-user quotas (systemd
# 256+) and the nvidia/quickshell builds need multi-GB of build space.
WORK=$(mktemp -d /var/tmp/ii-prebuild.XXXXXX); trap 'rm -rf "$WORK"' EXIT

step "prebuild — ${#ORDER[@]} AUR + ${#LOCAL_PKG_DIRS[@]} local PKGBUILDs"

for pkg in "${ORDER[@]}"; do
  if _is_git "$pkg"; then
    if _fresh_git_cache "$pkg"; then
      ok "$pkg: cached -git build <${GIT_FRESH_HOURS}h old"
      continue
    fi
    reason="-git (always rebuild)"
  else
    cur=$(_current_ver "$pkg")
    cached=$(_cached_ver "$pkg" 2>/dev/null || true)
    if [[ "$cached" == "$cur" && -n "$cached" ]]; then
      ok "$pkg: $cached"
      continue
    fi
    if [[ -n "$cached" && -z "$cur" ]]; then
      warn "$pkg: $cached (couldn't check upstream — keeping cache)"
      continue
    fi
    reason="cached=${cached:-none} upstream=${cur:-?}"
  fi
  step "build $pkg ($reason)"
  if d=$(_local_dir "$pkg"); then
    _build "$d" "$pkg (override)" "$pkg"
  else
    clone="$pkg"
    base=$(_aur_base "$pkg" 2>/dev/null) || base=""
    [[ -n "$base" ]] && clone="$base"
    ( cd "$WORK" && rm -rf "$clone" && git clone --depth=1 "https://aur.archlinux.org/$clone.git" "$clone" ) \
      || die "git clone failed for $pkg"
    [[ -f "$WORK/$clone/PKGBUILD" ]] || die "no PKGBUILD after AUR clone: $pkg ($clone)"
    _build "$WORK/$clone" "$pkg (AUR)" "$pkg"
  fi
done

for d in "${LOCAL_PKG_DIRS[@]}"; do
  [[ -f "$d/PKGBUILD" ]] || continue
  pkg=$(basename "$d")
  if _is_git "$pkg"; then
    if _fresh_git_cache "$pkg"; then
      ok "$pkg: cached -git build <${GIT_FRESH_HOURS}h old"
      continue
    fi
    reason="-git (always rebuild)"
  else
    cur=$(_pkgbuild_ver "$d/PKGBUILD" || true)
    cached=$(_cached_ver "$pkg" 2>/dev/null || true)
    if [[ "$cached" == "$cur" && -n "$cached" ]]; then
      ok "$pkg: $cached"
      continue
    fi
    reason="cached=${cached:-none} PKGBUILD=${cur:-?}"
  fi
  step "build $pkg ($reason)"
  _build "$d" "$pkg (upstream)" "$pkg"
done

step "re-index [$REPO_NAME]"
cd "$REPO_PATH"
shopt -s nullglob; declare -a all=( *.pkg.tar.* ); shopt -u nullglob
(( ${#all[@]} > 0 )) || die "no packages in $REPO_PATH"
sudo rm -f "$REPO_NAME".db* "$REPO_NAME".files*
sudo repo-add "$REPO_DB" "${all[@]}" >/dev/null
ok "${#all[@]} packages indexed"

step "verify required packages present + indexed"
missing=()
for pkg in "${REQUIRED[@]}"; do
  shopt -s nullglob; hits=( "$REPO_PATH/$pkg-"*.pkg.tar.* ); shopt -u nullglob
  has_file=false
  for f in "${hits[@]}"; do [[ "$f" != *-debug-* ]] && has_file=true; done
  $has_file || missing+=("$pkg (no .pkg.tar.*)")
  tar -tf "$REPO_DB" 2>/dev/null | grep -E "^$pkg-[^/]+/desc$" | grep -v -- '-debug-' | grep -q . \
    || missing+=("$pkg (not in DB)")
done
(( ${#missing[@]} == 0 )) || die "missing: ${missing[*]}"
ok "all ${#REQUIRED[@]} required packages ready"

# ── stage AUR nvidia packages into the prepared profile ────────────────────
# Done here (as the user, after the artifacts exist) so build/ never
# collects root-owned files. chroot.sh adds the official packages + dep
# closure and indexes the stash; ii-post-install hardware-detects from it.
NV_AUR_LIST="$BUILD/airootfs/root/nvidia-aur.txt"
if [[ -s "$NV_AUR_LIST" ]]; then
  step "stage AUR nvidia packages → airootfs nvidia stash"
  install -d "$BUILD/airootfs/usr/share/illogical-impulse/nvidia"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    f=$(ls -t "$REPO_PATH/$p-"*.pkg.tar.* 2>/dev/null | grep -v -- '-debug-' | head -1 || true)
    [[ -n "$f" ]] || die "nvidia AUR package missing from $REPO_PATH: $p"
    cp -f "$f" "$BUILD/airootfs/usr/share/illogical-impulse/nvidia/"
  done < "$NV_AUR_LIST"
  ok "$(ls "$BUILD/airootfs/usr/share/illogical-impulse/nvidia" | wc -l) packages staged"
fi
