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
