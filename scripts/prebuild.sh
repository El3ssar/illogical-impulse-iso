#!/usr/bin/env bash
# prebuild — build AUR/local PKGBUILDs into the local [ii-extra] pacman repo
# that mkarchiso pulls from during pacstrap.
#
# Per-package cache decision:
#   *-git           → always rebuild
#   local PKGBUILD  → source it, compare pkgver-pkgrel to cached filename
#   plain AUR       → query AUR RPC, compare Version to cached filename
#   match           → skip
#   mismatch/none   → makepkg into staging, replace the cached artifact, index
#   RPC failure     → trust cache (don't rebuild on transient network errors)
#
# The cache replace (rm-then-mv of the EXACT-named artifact) happens AFTER a
# successful makepkg, so a build failure leaves the previous version intact for
# the next mkarchiso run. It is a delete-then-rename, not a single atomic op —
# but it only ever runs post-success, so the window it opens is a momentary
# absence of one package between two indexings, never an empty/corrupt cache.
#
# Name matching everywhere is EXACT on the pkgname parsed from the artifact
# filename — never a `$name-*` prefix glob, which would let `python` clobber or
# misread a sibling like `python-build` (PB-02). Stale cache members no longer
# in the required set are pruned only AFTER a fully successful run (PB-05),
# preserving BUILD-01's "wipe only after success" invariant.

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
  f=$(_newest_cached_exact "$pkg") || true   # exact name — no `$pkg-*` sibling (PB-02)
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

# Single AUR RPC per package name, memoised. _aur_ver (the cache-decision
# lookup) and _aur_base (the clone-target lookup) read the SAME cached JSON,
# so a transient SECOND RPC can't be fatal for a pkgbase≠pkgname split package,
# and there's no TOCTOU between "version says rebuild" and "where do I clone"
# (PB-04). A confirmed failure is memoised as "" so a down server isn't re-hit.
declare -A AUR_JSON=()
declare -A AUR_TRIED=()
_aur_rpc() {
  local arg="$1" j
  if [[ -n "${AUR_TRIED[$arg]:-}" ]]; then
    [[ -n "${AUR_JSON[$arg]:-}" ]] || return 1
    printf '%s' "${AUR_JSON[$arg]}"; return 0
  fi
  AUR_TRIED["$arg"]=1
  if j=$(curl -fsS --max-time 5 "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$arg"); then
    AUR_JSON["$arg"]="$j"
    printf '%s' "$j"; return 0
  fi
  AUR_JSON["$arg"]=""
  return 1
}

_aur_ver() {
  local j
  j=$(_aur_rpc "$1") || return 1
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
  j=$(_aur_rpc "$1") || return 1
  python3 -c '
import json, sys
r = json.loads(sys.argv[1]).get("results") or []
if not r or not r[0].get("PackageBase"): sys.exit(1)
print(r[0]["PackageBase"])
' "$j" 2>/dev/null
}

# pkgname parsed from an artifact basename by stripping -pkgver-pkgrel-arch and
# the .pkg.tar.* suffix — the canonical split used everywhere we need a name.
_pkg_name_from_file() {
  local b="${1##*/}"
  printf '%s' "${b%-*-*-*}"
}

# Remove every cached artifact (and its .sig) whose parsed pkgname EXACTLY
# equals $1 (or its matching $1-debug split) — never a `$name-*` prefix glob,
# which would also delete dash-prefix siblings (staging `python` would erase a
# cached `python-build`). The replacing build only ever stages the non-debug
# artifact, so the stale debug member must be cleared by name too. (PB-02)
_rm_cached_exact() {
  local name="$1" f fn
  shopt -s nullglob
  for f in "$REPO_PATH"/*.pkg.tar.*; do
    [[ "$f" == *.sig ]] && continue
    fn="$(_pkg_name_from_file "$f")"
    [[ "$fn" == "$name" || "$fn" == "$name-debug" ]] || continue
    sudo rm -f "$f" "$f.sig"
  done
  shopt -u nullglob
}

# Path of the newest non-debug, non-sig cached artifact whose parsed pkgname
# EXACTLY equals $1, "" if none. Replaces `ls -t "$REPO_PATH/$x-"*` head-1 picks
# that a dash-prefix sibling could win (PB-02). mtime ordering via `ls -t`.
_newest_cached_exact() {
  local name="$1" f
  local -a hits=()
  shopt -s nullglob
  for f in "$REPO_PATH"/*.pkg.tar.*; do
    [[ "$f" == *-debug-* || "$f" == *.sig ]] && continue
    [[ "$(_pkg_name_from_file "$f")" == "$name" ]] && hits+=("$f")
  done
  shopt -u nullglob
  (( ${#hits[@]} )) || return 1
  ls -t "${hits[@]}" 2>/dev/null | head -1
}

# Version of the EXACTLY-named cached artifact, "" if absent. Iterate the whole
# repo and compare the parsed pkgname for equality — NOT a `$pkg-*` prefix glob,
# which matched dash-prefix siblings (looking up `python` returned the version
# of a cached `python-build`). (PB-02)
_cached_ver() {
  local pkg="$1" f b rest
  shopt -s nullglob
  for f in "$REPO_PATH"/*.pkg.tar.*; do
    [[ "$f" == *-debug-* ]] && continue
    [[ "$f" == *.sig ]] && continue   # read the version from packages, not signatures (BUILD-01)
    [[ "$(_pkg_name_from_file "$f")" == "$pkg" ]] || continue
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

# Build a PKGBUILD dir into staging; on success, replace the same-named cached
# artifact(s) in the [ii-extra] repo and index them. (Replace = delete-then-mv,
# only ever post-success — see the header note on why that's safe, not atomic.)
# Every staged pkgname is recorded in STAGED_NAMES so the end-of-run prune keeps
# split siblings this run produced (PB-05). Args: src_dir, label, pkgname
declare -A STAGED_NAMES=()
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
  local -a staged_paths=()
  for b in "${built[@]}"; do
    base="${b##*/}"
    [[ "$base" == *-debug-* ]] && continue
    # Detached signatures aren't packages: a signing-enabled host (BUILDENV+=sign
    # / a GPGKEY) drops $base.sig next to each artifact, and repo-add chokes on it
    # ("not a package file") — under set -e that aborts the whole build. Mirror
    # chroot.sh's _nv_pkgs filter and never stage/index a .sig. (BUILD-01)
    [[ "$base" == *.sig ]] && continue
    name="$(_pkg_name_from_file "$base")"   # strip pkgver-pkgrel-arch.pkg.tar.*
    _rm_cached_exact "$name"   # exact name only — no `$name-*` sibling clobber (PB-02)
    sudo mv "$b" "$REPO_PATH/"
    staged_paths+=("$REPO_PATH/$base")
    STAGED_NAMES["$name"]=1   # remembered so the end-of-run prune keeps it (PB-05)
    info "staged $base"
    staged=$((staged + 1))
    [[ "$name" == "$pkg" ]] && have_pkg=1
  done
  (( staged > 0 ))   || die "no artifacts in build output for $label"
  (( have_pkg > 0 )) || die "build of $label produced no $pkg package"
  # Index immediately + resync: later PKGBUILDs in THIS run may depend on
  # what was just built (the final full re-index still happens at the end).
  sudo repo-add -q "$REPO_DB" "${staged_paths[@]}" >/dev/null
  sudo "$PACMAN_II" -Sy >/dev/null 2>&1 || true
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

# makepkg -s resolves missing deps with plain pacman + the SYSTEM
# pacman.conf, which doesn't know [ii-extra] — so intra-run dependencies
# (quickshell-git needs our qt6-avif-image-plugin) fail on any fresh
# machine/container. makepkg honors $PACMAN: hand it a wrapper that adds
# the cache repo, and keep the repo db indexed as packages land.
PB_CONF="$WORK/pacman-ii.conf"
if grep -q '^\[ii-extra\]' /etc/pacman.conf; then
  cp /etc/pacman.conf "$PB_CONF"
else
  sed "/^\[core\]/i [ii-extra]\nSigLevel = Optional TrustAll\nServer = file://$REPO_PATH" \
    /etc/pacman.conf > "$PB_CONF"
fi
PACMAN_II="$WORK/pacman-ii"
printf '#!/bin/bash\nexec /usr/bin/pacman --config %q "$@"\n' "$PB_CONF" > "$PACMAN_II"
chmod +x "$PACMAN_II"
export PACMAN="$PACMAN_II"
[[ -f "$REPO_DB" ]] || sudo repo-add -q "$REPO_DB"
sudo "$PACMAN_II" -Sy >/dev/null || warn "pacman -Sy failed (offline?) — dep resolution may use stale dbs"

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

# ── prune obsolete cache members (PB-05) ───────────────────────────────────
# The cache used to only grow: a member no longer required lingered forever, and
# because [ii-extra] is ordered BEFORE core/extra a stale equal-or-higher
# version could SHADOW an official package at pacstrap. Now that every build
# above succeeded (set -e would have aborted otherwise — keeping BUILD-01's
# "wipe only after a successful run" invariant), drop any artifact whose pkgname
# is NOT in the keep set: the required AUR names, the local PKGBUILD names, and
# every split sibling THIS run staged (STAGED_NAMES) — plus each one's -debug
# split. This never deletes a package some required entry still needs.
step "prune obsolete [$REPO_NAME] members"
declare -A KEEP=()
for pkg in "${REQUIRED[@]}";          do KEEP["$pkg"]=1; done
for d   in "${LOCAL_PKG_DIRS[@]}";    do KEEP["$(basename "$d")"]=1; done
for pkg in "${!STAGED_NAMES[@]}";     do KEEP["$pkg"]=1; done
pruned=0
shopt -s nullglob
for f in "$REPO_PATH"/*.pkg.tar.*; do
  [[ "$f" == *.sig ]] && continue
  n="$(_pkg_name_from_file "$f")"
  base="${n%-debug}"   # a foo-debug member is kept iff foo is kept
  [[ -n "${KEEP[$base]:-}" ]] && continue
  sudo rm -f "$f" "$f.sig"
  info "pruned ${f##*/}"
  pruned=$((pruned + 1))
done
shopt -u nullglob
ok "$pruned obsolete artifact(s) pruned"

step "re-index [$REPO_NAME]"
cd "$REPO_PATH"
# Drop detached .sig from the index input — repo-add treats them as packages and
# fails. Keep debug packages (they're indexed as before). (BUILD-01)
shopt -s nullglob
declare -a all=()
for f in *.pkg.tar.*; do [[ "$f" == *.sig ]] && continue; all+=("$f"); done
shopt -u nullglob
(( ${#all[@]} > 0 )) || die "no packages in $REPO_PATH"
sudo rm -f "$REPO_NAME".db* "$REPO_NAME".files*
sudo repo-add "$REPO_DB" "${all[@]}" >/dev/null
ok "${#all[@]} packages indexed"

step "verify required packages present + indexed"
# DB entries are "<pkgname>-<pkgver>-<pkgrel>/desc"; collect each non-debug
# entry's EXACT pkgname once so the per-package check is a fixed-string set
# lookup, not a `$pkg`-as-ERE grep (names with +/. mis-matched). (PB-03)
declare -A DB_NAMES=()
while IFS= read -r e; do
  e="${e%/desc}"                     # strip the /desc suffix
  [[ "$e" == */* ]] && continue      # only top-level <name-ver-rel> entries
  n="${e%-*-*}"                       # strip -pkgver-pkgrel
  [[ "$n" == *-debug ]] && continue  # debug split doesn't satisfy a requirement
  DB_NAMES["$n"]=1
done < <(tar -tf "$REPO_DB" 2>/dev/null | grep -- '/desc$')

missing=()
for pkg in "${REQUIRED[@]}"; do
  has_file=false
  shopt -s nullglob
  for f in "$REPO_PATH"/*.pkg.tar.*; do
    # A lone .sig must not satisfy "package present" (BUILD-01); match the
    # EXACT parsed name, not a `$pkg-*` prefix that catches siblings. (PB-02)
    [[ "$f" == *.sig || "$f" == *-debug-* ]] && continue
    [[ "$(_pkg_name_from_file "$f")" == "$pkg" ]] && { has_file=true; break; }
  done
  shopt -u nullglob
  $has_file || missing+=("$pkg (no .pkg.tar.*)")
  [[ -n "${DB_NAMES[$pkg]:-}" ]] || missing+=("$pkg (not in DB)")
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
    # Newest EXACTLY-named artifact: a `$p-*` prefix glob could pick a dash-prefix
    # sibling (PB-02), and _newest_cached_exact already drops .sig/-debug so a
    # detached signature can't be staged (chroot.sh's repo-add would reject it,
    # BUILD-01).
    f=$(_newest_cached_exact "$p") || true
    [[ -n "$f" ]] || die "nvidia AUR package missing from $REPO_PATH: $p"
    cp -f "$f" "$BUILD/airootfs/usr/share/illogical-impulse/nvidia/"
  done < "$NV_AUR_LIST"
  ok "$(ls "$BUILD/airootfs/usr/share/illogical-impulse/nvidia" | wc -l) packages staged"
fi
