#!/usr/bin/env bash
# smoke — headless boot test of the newest out/*.iso. Boots in QEMU with no
# display, then probes QMP screendumps: the live session must reach rich
# graphical output (greetd → Hyprland → Quickshell). A text-only fallback
# (agreety on a VT after a session crash) yields almost no distinct colors
# and FAILS — which is exactly the regression this exists to catch.
#
#   smoke.sh [--timeout SECONDS]      (default 300)
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

T=$(mktemp -d); trap 'kill "$QPID" 2>/dev/null; rm -rf "$T"' EXIT
cp "$OVMF_VARS_SRC" "$T/vars.fd"

KVM_ARGS=()
[[ -w /dev/kvm ]] && KVM_ARGS=( -enable-kvm -cpu host ) || warn "no /dev/kvm — TCG (slow)"

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
