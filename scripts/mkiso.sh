#!/usr/bin/env bash
# mkiso — run mkarchiso on the prepared build/ profile. Self-escalates via
# sudo; run it as your normal user.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [[ $EUID -ne 0 ]]; then
  step "mkarchiso (sudo)"
  exec sudo -E env "PATH=$PATH" USER="$USER" HOME="$HOME" "$0" "$@"
fi

[[ -f "$BUILD/profiledef.sh" ]] || die "build/ not prepared — run: just prepare"
require mkarchiso

# BUILD-05: assert this (unpinned, host-supplied) mkarchiso still runs our
# customize_airootfs.sh hook. chroot.sh is staged as /root/customize_airootfs.sh
# and mkarchiso runs it via a mechanism it ITSELF warns is deprecated. If a host
# archiso bump drops that support, the keyring/paru/wheelhouse/liveuser-seed/
# microcode-stash/sanity-gate bootstrap SILENTLY stops running — the ISO still
# builds but ships broken. Fail LOUDLY here instead. (The builder container pins
# archiso; this re-checks the actually-installed binary at build time.)
_mkarchiso_bin="$(command -v mkarchiso)"
if ! grep -q 'customize_airootfs\.sh' "$_mkarchiso_bin" 2>/dev/null; then
  die "mkarchiso ($_mkarchiso_bin) no longer references customize_airootfs.sh — the chroot bootstrap hook would SILENTLY not run (BUILD-05). Pin archiso to a supported version (see containers/builder.Dockerfile) or port chroot.sh off the deprecated hook."
fi

# NOTE: deliberately nothing here writes into $BUILD — this script runs as
# root, and root-owned files in build/ would break the next user-level
# prepare wipe. Staging into the profile happens in prebuild.sh (as user).

install -d "$OUT"
rm -rf "$WORKDIR"
step "mkarchiso → $OUT"
if mkarchiso -v -w "$WORKDIR" -o "$OUT" "$BUILD"; then
  rm -rf "$WORKDIR"
  ok "ISO built:"
  ls -lh "$OUT"/*.iso | sed 's/^/      /' >&2
else
  die "mkarchiso failed — workdir kept at $WORKDIR"
fi
