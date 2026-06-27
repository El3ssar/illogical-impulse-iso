#!/usr/bin/env bash
# revert-roundtrip.sh — HOST driver for the Iron Law end-to-end round-trip test
# (TEST-02, #81). Tier-2 of the test ladder (real installed-system stand-in, no
# ISO bake): it runs the in-container payload (tests/revert-roundtrip.in.sh)
# inside a throwaway `just nspawn` container and propagates its pass/fail.
#
# What it proves: the project's central promise on the REAL, already-merged code —
# seed a few ledger kinds through the real mutators + the real pack engine, then
# `iictl revert-all` and assert the box is byte-for-byte back to vanilla. See the
# payload's header for the full assertion list. This driver itself changes
# nothing on the host: the container boots --volatile=overlay, so every write
# evaporates on exit; the cached base rootfs is never mutated.
#
# Usage:
#   tests/revert-roundtrip.sh          run the round-trip (assembles build/ if needed)
#   just test-revert                   the wrapper recipe (same thing)
#
# The payload is shipped into the container by base64-embedding it in the
# one-shot command `just nspawn` runs — NOTHING is copied into build/ or baked
# into any image, so the test is residue-free and the squashfs never carries it.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

PAYLOAD="$ROOT/tests/revert-roundtrip.in.sh"
[[ -f "$PAYLOAD" ]] || die "missing in-container payload: $PAYLOAD"

# The container needs the staged runtime layer (iictl + the survive-path libs);
# nspawn.sh rsyncs build/airootfs/usr/local in. Assemble build/ if it is not
# already present, so the test is runnable from a clean checkout in CI.
if [[ ! -d "$BUILD/airootfs/usr/local/lib/ii" ]]; then
  step "build/ not assembled — running 'just prepare' first"
  ( cd "$ROOT" && ./scripts/prepare.sh ) || die "prepare failed — cannot stage the runtime layer for the test"
fi

require base64 systemd-nspawn

# Embed the payload as base64 so it survives the single-arg quoting `just nspawn`
# applies ({{ quote(args) }}) with zero shell-metachar hazard. Inside the
# container we decode it to a tmpfile and run it; the container is ephemeral.
step "running the reversibility round-trip inside a throwaway nspawn container"
B64="$(base64 -w0 < "$PAYLOAD")"
IN_CMD="set -e; printf '%s' '$B64' | base64 -d > /tmp/ii-revert-roundtrip.sh; bash /tmp/ii-revert-roundtrip.sh"

# Delegate to the nspawn recipe surface (self-sudoes; --volatile=overlay). The
# container command's exit code propagates out of systemd-nspawn, so a failing
# assertion reds this script — and therefore the CI job / `just test-revert`.
exec "$SCRIPTS/nspawn.sh" "$IN_CMD"
