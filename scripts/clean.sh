#!/usr/bin/env bash
# clean [--hard] — remove build/ (--hard: also out/ + the mkarchiso workdir).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

step "clean"
_wipe "$BUILD"; ok "build/ removed"
if [[ "${1:-}" == "--hard" ]]; then
  rm -rf "$OUT" && ok "out/ removed"
  sudo rm -rf "$WORKDIR" 2>/dev/null && ok "$WORKDIR removed" || true
fi
