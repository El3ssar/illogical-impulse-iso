#!/usr/bin/env bash
# nspawn — throwaway systemd-nspawn container for testing CLI / script
# behaviour (iictl verbs, the ledger, packs, choosers, service toggles) on a
# real installed-system stand-in WITHOUT baking an ISO or booting QEMU.
#
#   nspawn.sh                  root shell inside a disposable copy of the distro
#   nspawn.sh '<command…>'     run one command in the container, then exit
#   nspawn.sh --clean          remove the cached base rootfs (.nspawn-cache/)
#
# Tier-2 of the test ladder: faster than `just build`+`just vm` (Tier-4),
# complements `just preview` (Tier-1, Quickshell UI). Graphics / Hyprland are
# out of scope — use preview or the VM for those.
#
# Ephemerality: the container boots with --volatile=overlay (read-only base +
# tmpfs upper), so EVERY write inside (package installs, ledger rows, config
# edits) lands in RAM and evaporates on exit — the cached base is never mutated
# by a run. The only persistent artifact is the git-ignored .nspawn-cache/ base
# rootfs (pacstrap'd once, reused); `--clean` removes it. Needs root (pacstrap +
# systemd-nspawn): it self-sudoes.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CACHE="${II_NSPAWN_CACHE:-$ROOT/.nspawn-cache}"
BASE="$CACHE/base"
STAMP="$CACHE/base.stamp"
# Minimal bootable rootfs + iictl's hard deps. Bump the tag when this set (or
# the staging step below) changes, so the cached base is rebuilt on next run.
BASE_PKGS=(base git sudo)
BASE_TAG="v1: ${BASE_PKGS[*]}"

usage() {
  cat >&2 <<EOF
just nspawn — throwaway container to test CLI / iictl behaviour (no ISO bake)

  just nspawn                interactive root shell in a disposable distro copy
  just nspawn '<command…>'   run one command in the container, then exit
  just nspawn --clean        remove the cached base rootfs (.nspawn-cache/)

Every in-container change is discarded on exit (--volatile=overlay). Needs root
(self-sudoes). Run 'just prepare' first so build/ holds the runtime layer.
EOF
  exit "${1:-0}"
}

case "${1:-}" in -h|--help|help) usage 0 ;; esac

# pacstrap, systemd-nspawn and the root-owned cache all need root. Re-exec under
# sudo (help is handled above so it never prompts).
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null || die "root required (pacstrap + systemd-nspawn); sudo not found"
  exec sudo --preserve-env=II_NSPAWN_CACHE "$SCRIPTS/nspawn.sh" "$@"
fi

CLEAN=false
case "${1:-}" in --clean) CLEAN=true; shift ;; esac

if $CLEAN; then
  step "removing $CACHE"
  _wipe "$CACHE"
  ok "cache cleared"
  exit 0
fi

require systemd-nspawn pacstrap rsync

# Our runtime layer lives in build/airootfs — it must be assembled first.
[[ -d "$BUILD/airootfs/usr/local/lib/ii" ]] \
  || die "build/ not assembled — run: just prepare"

# ── 1. cached base rootfs (the expensive step; rebuilt only on recipe change) ─
if [[ ! -d "$BASE" || "$(cat "$STAMP" 2>/dev/null)" != "$BASE_TAG" ]]; then
  step "pacstrap base rootfs → ${BASE#"$ROOT"/}  (one-time; cached, needs network)"
  _wipe "$BASE"
  install -d "$BASE"
  # LC_ALL=C: the fresh chroot has no generated locales yet, so package hooks'
  # perl spews "Setting locale failed" if the host's UTF-8 LANG leaks in. C is
  # always present — silences the noise without changing what gets installed.
  LC_ALL=C LANG=C pacstrap -c -K "$BASE" "${BASE_PKGS[@]}" \
    || die "pacstrap failed (no network / cold cache?)"
  printf '%s\n' "$BASE_TAG" > "$STAMP"
  ok "base rootfs built"
else
  info "reusing cached base rootfs (${BASE#"$ROOT"/})"
fi

# ── 2. overlay our runtime layer onto the base ───────────────────────────────
# Mirrors how mkarchiso overlays overlay/airootfs onto the pacstrapped rootfs,
# but only the distro bits a CLI test needs. rsync -a preserves the +x the iictl
# resolver checks for (no mkarchiso cp --no-preserve=mode strip here). This runs
# every invocation so the layer is always current without a base rebuild.
step "stage distro runtime layer (iictl, iictl.d/, ledger, release stamp)"
# install -d each destination first: a pacstrap base already ships /usr/local,
# /usr/share and /etc/skel (the `filesystem` package), but creating them makes
# the rsync independent of that and lets `rsync -a` (no --mkpath) fill them.
_stage() {  # <src-rel> ; rsync build/airootfs/<src-rel>/ → base/<src-rel>/ if present
  local rel="$1"
  [[ -d "$BUILD/airootfs/$rel" ]] || return 0
  install -d "$BASE/$rel"
  rsync -a "$BUILD/airootfs/$rel/" "$BASE/$rel/"
}
_stage usr/local
_stage "usr/share/illogical-impulse"
_stage "etc/$DISTRO_ID"
_stage etc/skel
[[ -f "$BUILD/airootfs/etc/os-release" ]] \
  && install -Dm0644 "$BUILD/airootfs/etc/os-release" "$BASE/etc/os-release"
ok "runtime layer staged"

# ── 3. boot ephemerally — every write below the base is discarded on exit ────
# NS[0] is the binary itself, so the launch is `exec "${NS[@]}"` — NOT
# `exec systemd-nspawn "${NS[@]}"`, which would pass a stray "systemd-nspawn" as
# the first positional. systemd-nspawn stops option parsing at the first
# non-option, so that stray arg makes it ignore -D and fall back to $PWD as the
# container dir ("doesn't look like it has an OS tree. Refusing.").
NS=( systemd-nspawn -q --volatile=overlay -D "$BASE" --hostname="$DISTRO_ID" )
if (( $# )); then
  step "one-shot in throwaway $DISTRO_ID: $*   (changes discarded on exit)"
  exec "${NS[@]}" /bin/bash -c "$*"
else
  step "root shell in throwaway $DISTRO_ID   (exit / Ctrl-D discards everything)"
  exec "${NS[@]}"
fi
