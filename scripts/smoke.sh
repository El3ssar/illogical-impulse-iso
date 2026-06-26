#!/usr/bin/env bash
# smoke — headless boot test of the newest out/*.iso. Boots in QEMU with no
# display, then probes QMP screendumps: the live session must reach rich
# graphical output (greetd → Hyprland → Quickshell). A text-only fallback
# (agreety on a VT after a session crash) yields almost no distinct colors
# and FAILS — which is exactly the regression this exists to catch.
#
#   smoke.sh [--timeout SECONDS]      (default 300)
#
# Requires hardware virtualization (KVM). The probe boots a full UEFI ISO all
# the way into a graphical session, which effectively never completes within the
# timeout under TCG software emulation — so with no writable /dev/kvm this FAILS
# FAST with a clear message instead of hanging to a misleading timeout (CI-03).
# Set SMOKE_ALLOW_TCG=1 to force the slow TCG path anyway (expect it to time out
# on real ISOs). On GitHub-hosted ubuntu-latest, /dev/kvm exists but the runner
# user needs the enable step in release.yml to make it writable.
#
# Used by `just smoke` locally and by the release CI before publishing.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require qemu-system-x86_64 python3

TIMEOUT=300
[[ "${1:-}" == "--timeout" ]] && TIMEOUT="${2:?--timeout needs seconds}"

shopt -s nullglob; _isos=("$OUT"/*.iso); shopt -u nullglob
(( ${#_isos[@]} > 0 )) || die "no ISO in $OUT — just build"
ISO="$(ls -t "$OUT"/*.iso | head -1)"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
done
[[ -n "$OVMF_CODE" ]] || die "OVMF firmware not found (edk2-ovmf / ovmf package)"
OVMF_VARS_SRC="${OVMF_CODE/CODE/VARS}"
[[ -f "$OVMF_VARS_SRC" ]] || die "OVMF VARS template missing: $OVMF_VARS_SRC"

# KVM gate (CI-03) — decided BEFORE we allocate the tempdir/trap so an early
# `die` can't trip the EXIT trap's (still-unset) $QPID. The probe below needs a
# real cold boot into a graphical session; under TCG software emulation that
# never finishes in time, so a KVM-less run would silently hang to its timeout.
# Fail fast with a clear message instead — unless the caller opts into the slow
# TCG path with eyes open via SMOKE_ALLOW_TCG=1.
KVM_ARGS=()
if [[ -w /dev/kvm ]]; then
  KVM_ARGS=( -enable-kvm -cpu host )
elif [[ -n "${SMOKE_ALLOW_TCG:-}" ]]; then
  warn "KVM required for the graphical probe, but SMOKE_ALLOW_TCG is set — booting under TCG software emulation (very slow; a real ISO will likely time out within ${TIMEOUT}s)"
else
  die "KVM required for the graphical probe: /dev/kvm is absent or not writable. This boots a full UEFI ISO into a Hyprland/Quickshell graphical session and counts distinct framebuffer colors; under TCG emulation that boot does not finish in time, so the run would hang to a misleading timeout rather than fail here. Run on a KVM-capable host/runner (kvm group + writable /dev/kvm), or set SMOKE_ALLOW_TCG=1 to force the slow TCG path with eyes open."
fi

T=$(mktemp -d); trap 'kill "$QPID" 2>/dev/null; rm -rf "$T"' EXIT
cp "$OVMF_VARS_SRC" "$T/vars.fd"

step "smoke-boot $(basename "$ISO") (timeout ${TIMEOUT}s)"
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -machine q35 -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$T/vars.fd" \
  -cdrom "$ISO" -boot d \
  -device virtio-vga \
  -display none \
  -qmp "unix:$T/qmp.sock,server,nowait" \
  -nic none &
QPID=$!

# Probe: QMP screendump → PPM → count distinct colors on a sample grid.
_probe() {
  python3 - "$T/qmp.sock" "$T/dump.ppm" <<'PY'
import json, socket, sys, time
sock_path, dump_path = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock_path); f = s.makefile("rw")
json.loads(f.readline())                     # greeting
def cmd(c, **a):
    f.write(json.dumps({"execute": c, **({"arguments": a} if a else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd("qmp_capabilities")
r = cmd("screendump", filename=dump_path)
if "error" in r: print(0); sys.exit(0)
time.sleep(0.5)
with open(dump_path, "rb") as img:
    assert img.readline().strip() == b"P6"
    line = img.readline()
    while line.startswith(b"#"): line = img.readline()
    w, h = map(int, line.split()); img.readline()
    data = img.read()
colors = set()
for y in range(0, h, max(1, h // 80)):
    for x in range(0, w, max(1, w // 80)):
        i = (y * w + x) * 3
        colors.add(data[i:i+3])
print(len(colors))
PY
}

ELAPSED=0
BEST=0
while (( ELAPSED < TIMEOUT )); do
  sleep 30; ELAPSED=$((ELAPSED + 30))
  kill -0 "$QPID" 2>/dev/null || die "qemu died at ${ELAPSED}s"
  N=$(_probe 2>/dev/null || echo 0)
  (( N > BEST )) && BEST=$N
  info "${ELAPSED}s: $N distinct colors on screen"
  if (( N >= 16 )); then
    ok "graphical session reached (${N} colors at ${ELAPSED}s)"
    exit 0
  fi
done
die "no graphical session within ${TIMEOUT}s (best probe: $BEST colors — text fallback or black screen)"
