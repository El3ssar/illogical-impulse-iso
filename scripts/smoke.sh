#!/usr/bin/env bash
# smoke — the functional merge/release gate for the newest out/*.iso.
#
#   smoke.sh                 STAGE 1 ONLY — headless boot + colour-diversity probe
#                            (the release-CI gate; behaviour UNCHANGED, see below)
#   smoke.sh --full          stage 1 + the post-boot functional battery (stages 2–5)
#   smoke.sh --build         run `just build` first, then the stage-1 boot probe
#   smoke.sh --build --full  bake fresh, then the whole battery
#   smoke.sh --timeout SECS  boot-probe timeout (default 300; --full adds its own)
#
# ── STAGE 1 (verbatim, the release-CI gate) ─────────────────────────────────
# Boots the ISO in QEMU with no display, then probes QMP screendumps: the live
# session must reach rich graphical output (greetd → Hyprland → Quickshell). A
# text-only fallback (agreety on a VT after a session crash) yields almost no
# distinct colors and FAILS — exactly the regression this exists to catch. This
# is the ONLY thing `just smoke` (no args) runs, so the release pipeline's
# boot-only invocation is untouched.
#
# ── STAGES 2–5 (--full, the functional battery) ─────────────────────────────
# After stage 1 confirms the graphical session, `--full` exercises the distro's
# additive+reversible guarantees end to end INSIDE the booted live system, via a
# guest command channel (see below). In order:
#
#   Stage 2 — `iictl doctor` golden path: assert exit 0 (venv, greetd, boot
#             artifacts, pacman db unlocked). The cheapest whole-system probe.
#   Stage 3 — `qs -p` load check for EVERY standalone Quickshell shell.qml
#             discovered under /usr/share/illogical-impulse (welcome, control,
#             widgets/* …) — globbed, not hardcoded, so a newly-added standalone
#             app is covered automatically. Any QML load/parse error FAILS.
#   Stage 4 — pack round-trip ONLINE: capture a clean baseline, `iictl pack
#             install <probe>` then `remove`, asserting the members appear and
#             disappear. A probe pointed at a NONEXISTENT package must FAIL
#             loudly (a negative control). This stage needs NETWORKING — optional
#             packs install from the public mirrors + AUR ([ii-extra] does NOT
#             survive install), so the guest boots with a user-mode NIC.
#   Stage 5 — `iictl revert-all` idempotency: run it, assert the post-revert
#             manifest (sorted `pacman -Qq` + the ledger + owned paths) equals
#             the captured clean baseline, then run it AGAIN and assert a clean
#             no-op exit 0. This is the project's reversibility bug-class executed
#             as a test — the single property the Iron Law rests on.
#
# ── the guest command channel (test-only; nothing baked) ────────────────────
# stage 1 only observes via screendump. To drive `iictl` inside the guest, the
# harness attaches TWO small labelled vfat disks (mirroring install-smoke.sh's
# II_SEED/II_RESULT precedent) and a user-mode NIC:
#   II_PAYLOAD (ro)  — carries the assertion script THIS harness generates at
#                       runtime (a probe-pack name + the stage 2–5 logic). It is
#                       NOT baked into the ISO — it rides in on a throwaway disk,
#                       so the squashfs and every airootfs/overlay/skel path are
#                       untouched (the whole change is reversible by deleting this
#                       harness diff).
#   II_RESULT  (rw)  — where the in-guest payload stamps `result` (OK / FAIL:…)
#                       and copies logs back for host-side debugging.
# Once stage 1 confirms the session, the harness switches to the baked tty2
# autologin-root RESCUE shell via QMP keystrokes (Ctrl+Alt+F2) and types a short
# BOOTSTRAP one-liner that mounts II_PAYLOAD and execs the payload; the payload
# drops to `liveuser` (the real ledger-owning user) for the iictl round-trips,
# stamps II_RESULT, and powers off. No in-guest helper is baked — the harness
# reuses the tty2 rescue shell and the labelled-disk convention already shipped.
#
# ── prerequisites & how it complements validate.yml ─────────────────────────
# Requires hardware virtualization (KVM) + OVMF (edk2-ovmf). The probe boots a
# full UEFI ISO all the way into a graphical session, which effectively never
# completes within the timeout under TCG software emulation — so with no writable
# /dev/kvm this FAILS FAST with a clear message instead of hanging to a misleading
# timeout (CI-03). Set SMOKE_ALLOW_TCG=1 to force the slow TCG path anyway (expect
# it to time out on real ISOs). On GitHub-hosted ubuntu-latest, /dev/kvm exists
# but the runner user needs the enable step in release.yml to make it writable.
#
# `.github/workflows/validate.yml` is the PER-PR gate: `just prepare && just
# validate` — a static audit (~150 checks) that proves the profile ASSEMBLES
# correctly. It does NOT build an ISO and has no KVM. This harness is the
# complementary FUNCTIONAL gate: it BOOTS a real ISO and EXECUTES the guarantees
# static lint can only assert on paper (a pack really installs over the network;
# revert-all really returns to a clean baseline; a standalone config really
# loads). It is a LOCAL / release-pipeline step — never wired into the QEMU-less
# per-PR container.
#
# Local maintainer run (the merge gate):   just build && just smoke --full
# Expected runtime: stage 1 ~2–5 min to the graphical session on KVM; the full
# battery adds ~3–8 min (an online pack fetch dominates stage 4). Budget ~15 min.
#
# Used by `just smoke` locally and by the release CI before publishing.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require qemu-system-x86_64 python3

# ── argument parsing ────────────────────────────────────────────────────────
# Back-compat: `--timeout SECS` as the FIRST two args still works (the old
# calling convention); the new flags are order-independent.
TIMEOUT=300
FULL=false
BUILD=false
FULL_TIMEOUT="${SMOKE_FULL_TIMEOUT:-900}"   # wall clock for the post-boot battery
while (( $# )); do
  case "$1" in
    --timeout)      TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --full-timeout) FULL_TIMEOUT="${2:?--full-timeout needs seconds}"; shift 2 ;;
    --full)         FULL=true; shift ;;
    --build)        BUILD=true; shift ;;
    -h|--help)      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1 (try: smoke.sh --help)" ;;
  esac
done

# --build: bake a fresh ISO first (the maintainer merge-gate convenience). We
# shell out to `just build` from the repo root so the whole pipeline runs.
if $BUILD; then
  step "smoke --build: baking a fresh ISO (just build)"
  ( cd "$ROOT" && just build ) || die "just build failed — cannot smoke"
fi

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

# ── the --full guest channel: payload + result vfat disks, user-mode NIC ─────
# Built ONLY for --full; the boot-only stage-1 run stays `-nic none` with no
# extra disks, byte-for-byte the release-CI probe. The payload disk carries the
# assertion script this harness generates at runtime (see _build_payload); the
# result disk is where the in-guest run stamps its verdict.
NIC_ARGS=( -nic none )
EXTRA_DRIVES=()
PAYLOAD_IMG=""
RESULT_IMG=""

# _build_payload — generate the in-guest assertion script and pack it, plus a
# writable result image, into two labelled vfat disks. The script is authored
# here (host side) and NEVER baked into the ISO — it rides in on II_PAYLOAD.
_build_payload() {
  require mkfs.vfat
  local sdir="$T/payload"; mkdir -p "$sdir"

  # The in-guest payload. Runs as tty2 autologin ROOT; drops to `liveuser` (the
  # real ledger-owning session user) for every iictl round-trip via runuser, so
  # the ledger, venv, and $HOME all resolve to the live user exactly as on a real
  # box. Stamps result+logs onto II_RESULT, then powers off unconditionally so
  # the host's wall-clock guard is a backstop, not the norm. PROBE_PACK is the
  # small official-repo pack the round-trip exercises (demo → sl + cowsay).
  cat > "$sdir/ii-smoke-run.sh" <<'GUEST'
#!/usr/bin/env bash
# ii-smoke-run — in-guest functional battery for `smoke.sh --full`. Delivered on
# a throwaway II_PAYLOAD disk (NOT baked into the ISO); stamps its verdict onto
# II_RESULT and powers the VM off. Runs as tty2 autologin root.
set -u
LOG=/var/log/ii-smoke-run.log
exec > >(tee -a "$LOG") 2>&1
say() { echo "[ii-smoke-run] $*"; }

PROBE_PACK="demo"               # small official-repo pack: sl + cowsay
LIVE_USER="liveuser"
RESULT_MNT=""
VERDICT="FAIL: ii-smoke-run did not reach a verdict"

finish() {
  say "verdict: $VERDICT"
  if [[ -n "$RESULT_MNT" && -d "$RESULT_MNT" ]]; then
    printf '%s\n' "$VERDICT" > "$RESULT_MNT/result" 2>/dev/null || true
    cp -f "$LOG" "$RESULT_MNT/ii-smoke-run.log" 2>/dev/null || true
    # user-side log the payload writes as liveuser for host-side debugging
    cp -f "/home/$LIVE_USER/.ii-smoke.log" "$RESULT_MNT/ii-smoke-user.log" 2>/dev/null || true
    sync
    umount "$RESULT_MNT" 2>/dev/null || true
  fi
  sync
  say "powering off"
  systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || \
    { echo o > /proc/sysrq-trigger 2>/dev/null; }
  exit 0
}
trap finish EXIT

# ── mount the writable result disk ──────────────────────────────────────────
rdev=""
for _i in $(seq 1 30); do
  rdev=$(readlink -f /dev/disk/by-label/II_RESULT 2>/dev/null || true)
  [[ -b "$rdev" ]] && break
  sleep 1
done
[[ -b "$rdev" ]] || { VERDICT="FAIL: II_RESULT disk not found"; exit 0; }
RESULT_MNT=$(mktemp -d)
mount "$rdev" "$RESULT_MNT" || { VERDICT="FAIL: cannot mount II_RESULT"; RESULT_MNT=""; exit 0; }

# ── run the whole battery AS liveuser (the ledger/venv/$HOME owner) ─────────
# Everything the distro's reversibility contract touches lives under the live
# user's $HOME (ledger at ~/.local/state/illogical-impulse). Wait for that user
# to exist (greetd seeded it at build time, so it always does) and drop to it.
id "$LIVE_USER" >/dev/null 2>&1 || { VERDICT="FAIL: $LIVE_USER account missing"; exit 0; }

# The payload we hand runuser: it returns a single-line STAGE:verdict on failure
# via its own exit + a marker file. runuser carries a minimal env; iictl finds
# its libs by absolute path.
export PROBE_PACK
runuser -u "$LIVE_USER" -- bash -s <<'USER'
set -u
ULOG="$HOME/.ii-smoke.log"
exec > >(tee -a "$ULOG") 2>&1
ustep() { echo "== [$1] $2"; }
ufail() { echo "STAGE_FAIL:$1: $2"; exit 1; }

PROBE_PACK="${PROBE_PACK:-demo}"
export PATH="/usr/local/bin:$PATH"
SHARE=/usr/share/illogical-impulse

command -v iictl >/dev/null 2>&1 || ufail 0 "iictl not on PATH"

# ── STAGE 2 — iictl doctor golden path (exit 0) ─────────────────────────────
ustep 2 "iictl doctor"
iictl doctor || ufail 2 "iictl doctor returned non-zero (see doctor output above)"

# ── STAGE 3 — qs -p load check for every standalone shell.qml ───────────────
# Discover configs dynamically (welcome, control, widgets/* …). Each is plain
# QtQuick with ZERO quickshell/ii imports, so `qs -p <dir>` must load without a
# QML error. We run it briefly (qs stays resident rendering), capture stderr,
# then kill it: a load/parse error (missing import, syntax) surfaces on stderr
# and/or a non-zero early exit. An empty stderr + still-running qs = loaded OK.
ustep 3 "qs -p standalone-config load check"
command -v qs >/dev/null 2>&1 || ufail 3 "quickshell (qs) not found on the live ISO"
mapfile -t CONFIGS < <(find "$SHARE" -mindepth 2 -maxdepth 2 -name shell.qml -printf '%h\n' 2>/dev/null | sort)
(( ${#CONFIGS[@]} > 0 )) || ufail 3 "no standalone shell.qml found under $SHARE"
qs_errs=0
for cfg in "${CONFIGS[@]}"; do
  name="${cfg#"$SHARE"/}"
  errf="$(mktemp)"
  # -p <path>: load the config. Give it a moment to parse/instantiate, then stop.
  ( qs -p "$cfg" >/dev/null 2>"$errf" ) &
  qpid=$!
  sleep 6
  if kill -0 "$qpid" 2>/dev/null; then
    # still resident → it loaded. Stop it and inspect stderr for QML errors.
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null || true
    loaded=1
  else
    wait "$qpid" 2>/dev/null; loaded=0   # exited on its own → likely a load failure
  fi
  # A QML error prints lines like "file://…:NN: … Error" / "Unable to assign" /
  # "is not a type" / "cannot load" to stderr. Grep for the load-fatal signatures.
  if grep -Eiq 'error|cannot (load|assign)|is not a type|no such (file|property)|unable to' "$errf" \
     || (( ! loaded )); then
    echo "   qs load FAILED for $name:"; sed 's/^/     qs| /' "$errf"
    qs_errs=$((qs_errs + 1))
  else
    echo "   qs loaded OK: $name"
  fi
  rm -f "$errf"
done
(( qs_errs == 0 )) || ufail 3 "$qs_errs standalone config(s) failed to load"

# ── capture the CLEAN baseline BEFORE any pack install (for stage 5) ─────────
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/illogical-impulse"
LEDGER="$STATE/ledger.tsv"
_manifest() {   # sorted installed set + ledger data rows + owned paths → stdout
  echo "== packages =="; pacman -Qq | sort
  echo "== ledger =="
  [[ -f "$LEDGER" ]] && grep -v '^#' "$LEDGER" | sort || true
  echo "== owned =="
  iictl revert-all --dry-run 2>/dev/null | grep -E 'remove path' | sort || true
}
BASE_MANIFEST="$(_manifest)"

# ── STAGE 4 — pack round-trip ONLINE + a NEGATIVE control ───────────────────
ustep 4 "iictl pack install/remove $PROBE_PACK (online)"
iictl pack list >/dev/null 2>&1 || ufail 4 "iictl pack unavailable"
# Members must be ABSENT before install (baseline).
for m in sl cowsay; do
  pacman -Qq "$m" >/dev/null 2>&1 && ufail 4 "probe member '$m' already installed — cannot prove the round-trip"
done
iictl pack install "$PROBE_PACK" || ufail 4 "pack install $PROBE_PACK failed (network? mirrors?)"
for m in sl cowsay; do
  pacman -Qq "$m" >/dev/null 2>&1 || ufail 4 "pack installed but member '$m' is absent"
done
echo "   pack '$PROBE_PACK' installed; members present"

# NEGATIVE control: a pack pointed at a nonexistent package MUST fail loudly.
# We synthesize a throwaway pack list in a writable II_OPTDIR overlay so we do
# not touch the baked catalog. (The engine reads II_OPTDIR; point it at a temp
# dir seeded with the real lists PLUS a bogus one.)
ustep 4 "negative control — a nonexistent-package pack must FAIL"
BOGUS_DIR="$(mktemp -d)"
cp -a "$SHARE/optional/." "$BOGUS_DIR/" 2>/dev/null || true
printf '#meta:type example\nthis-package-does-not-exist-ii-smoke-xyzzy\n' > "$BOGUS_DIR/iismokebogus.list"
if II_OPTDIR="$BOGUS_DIR" iictl pack install iismokebogus >/dev/null 2>&1; then
  rm -rf "$BOGUS_DIR"
  ufail 4 "negative control PASSED install of a nonexistent package — the pack engine must fail loudly"
fi
rm -rf "$BOGUS_DIR"
echo "   negative control OK: nonexistent-package pack failed as required"

# Explicit remove leg of the round-trip.
ustep 4 "iictl pack remove $PROBE_PACK"
iictl pack remove "$PROBE_PACK" || ufail 4 "pack remove $PROBE_PACK failed"
for m in sl cowsay; do
  pacman -Qq "$m" >/dev/null 2>&1 && ufail 4 "pack removed but member '$m' lingers"
done
echo "   pack '$PROBE_PACK' removed; members gone"

# ── STAGE 5 — revert-all idempotency back to the captured baseline ──────────
# Re-install the probe so revert-all has something to undo, then revert-all,
# then assert the manifest matches the clean baseline. A second revert-all must
# be a clean no-op (exit 0).
ustep 5 "revert-all idempotency"
iictl pack install "$PROBE_PACK" || ufail 5 "re-install of $PROBE_PACK for the revert test failed"
iictl revert-all || ufail 5 "first revert-all returned non-zero"
POST_MANIFEST="$(_manifest)"
if [[ "$POST_MANIFEST" != "$BASE_MANIFEST" ]]; then
  echo "   MANIFEST DRIFT after revert-all:"
  diff <(printf '%s\n' "$BASE_MANIFEST") <(printf '%s\n' "$POST_MANIFEST") | sed 's/^/     diff| /'
  ufail 5 "revert-all did not restore the clean baseline (see diff above)"
fi
echo "   revert-all restored the clean baseline"
iictl revert-all || ufail 5 "second (idempotent) revert-all returned non-zero"
echo "   second revert-all is a clean no-op (idempotent)"

echo "ALL_STAGES_OK"
USER
rc=$?

# Read the liveuser log to determine the verdict (runuser's rc + the ALL_STAGES_OK
# marker). A STAGE_FAIL line in the user log names the failing stage.
ulog="/home/$LIVE_USER/.ii-smoke.log"
if (( rc == 0 )) && grep -q '^ALL_STAGES_OK$' "$ulog" 2>/dev/null; then
  VERDICT="OK"
else
  fail_line="$(grep -m1 '^STAGE_FAIL:' "$ulog" 2>/dev/null || true)"
  VERDICT="FAIL: ${fail_line:-battery aborted (rc=$rc); see ii-smoke-user.log}"
fi
exit 0
GUEST
  chmod +x "$sdir/ii-smoke-run.sh"

  PAYLOAD_IMG="$T/payload.img"
  truncate -s 16M "$PAYLOAD_IMG"
  mkfs.vfat -n II_PAYLOAD "$PAYLOAD_IMG" >/dev/null
  if command -v mcopy >/dev/null; then
    mcopy -i "$PAYLOAD_IMG" "$sdir/ii-smoke-run.sh" ::ii-smoke-run.sh
  else
    local _pm; _pm=$(mktemp -d)
    if mount -o loop "$PAYLOAD_IMG" "$_pm" 2>/dev/null || sudo mount -o loop "$PAYLOAD_IMG" "$_pm"; then
      cp "$sdir/ii-smoke-run.sh" "$_pm/" || sudo cp "$sdir/ii-smoke-run.sh" "$_pm/"
      sync; umount "$_pm" 2>/dev/null || sudo umount "$_pm"; rmdir "$_pm" 2>/dev/null || true
    else
      rmdir "$_pm"; die "cannot populate the payload vfat (install mtools, or run where loopback mount is allowed)"
    fi
  fi

  RESULT_IMG="$T/result.img"
  truncate -s 16M "$RESULT_IMG"
  mkfs.vfat -n II_RESULT "$RESULT_IMG" >/dev/null

  # user-mode NIC so the online pack stage (pacman + AUR) actually works, plus
  # the two labelled disks the payload mounts.
  NIC_ARGS=( -nic user,model=virtio-net-pci )
  EXTRA_DRIVES=(
    -drive "file=$PAYLOAD_IMG,if=virtio,format=raw,media=disk"
    -drive "file=$RESULT_IMG,if=virtio,format=raw,media=disk"
  )
  ok "guest channel built (II_PAYLOAD + II_RESULT, user-mode NIC) — probe pack: demo"
}

$FULL && _build_payload

step "smoke-boot $(basename "$ISO") (timeout ${TIMEOUT}s${FULL:+; --full battery after})"
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -machine q35 -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$T/vars.fd" \
  -cdrom "$ISO" -boot d \
  "${EXTRA_DRIVES[@]}" \
  -device virtio-vga \
  -display none \
  -qmp "unix:$T/qmp.sock,server,nowait" \
  "${NIC_ARGS[@]}" &
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
GRAPHICAL=false
while (( ELAPSED < TIMEOUT )); do
  sleep 30; ELAPSED=$((ELAPSED + 30))
  kill -0 "$QPID" 2>/dev/null || die "qemu died at ${ELAPSED}s"
  N=$(_probe 2>/dev/null || echo 0)
  (( N > BEST )) && BEST=$N
  info "${ELAPSED}s: $N distinct colors on screen"
  if (( N >= 16 )); then
    ok "graphical session reached (${N} colors at ${ELAPSED}s)"
    GRAPHICAL=true
    break
  fi
done
$GRAPHICAL || die "no graphical session within ${TIMEOUT}s (best probe: $BEST colors — text fallback or black screen)"

# ── boot-only (release CI): done at stage 1 ─────────────────────────────────
if ! $FULL; then
  exit 0
fi

# ═══════════════════════ STAGES 2–5 — the functional battery ════════════════
# The graphical session is up. Switch to the tty2 autologin-root RESCUE shell
# and type a short bootstrap one-liner that mounts II_PAYLOAD and execs the
# assertion payload. The payload runs the battery as liveuser, stamps II_RESULT,
# and powers the VM off. We then read the verdict off the result disk.

# _send_keys — drive tty2 + type the bootstrap via QMP send-key. qcodes are the
# QEMU key names (ctrl→ctrl, alt→alt, f2→f2, a-z/0-9/space/slash/dot/minus …).
_send_keys() {
  python3 - "$T/qmp.sock" <<'PY'
import json, socket, sys, time
sock_path = sys.argv[1]
s = socket.socket(socket.AF_UNIX); s.connect(sock_path); f = s.makefile("rw")
json.loads(f.readline())
def cmd(c, **a):
    f.write(json.dumps({"execute": c, **({"arguments": a} if a else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd("qmp_capabilities")
def press(codes):
    cmd("send-key", keys=[{"type": "qcode", "data": c} for c in codes]); time.sleep(0.06)
# char → qcode(s). Only the characters the bootstrap line uses are mapped.
SH = {
 ' ':['spc'],'/':['slash'],'.':['dot'],'-':['minus'],'_':['shift','minus'],
 ';':['semicolon'],'&':['shift','7'],'|':['shift','backslash'],
 '>':['shift','dot'],'=':['shift','0'],'"':['shift','apostrophe'],
 ':':['shift','semicolon'],'(':['shift','9'],')':['shift','0'],
 '$':['shift','4'],'*':['shift','8'],'\n':['ret'],
}
def typ(text):
    for ch in text:
        if ch in SH: press(SH[ch])
        elif ch.isdigit(): press([ch])
        elif ch.islower(): press([ch])
        elif ch.isupper(): press(['shift', ch.lower()])
        else: press(['spc'])
        time.sleep(0.01)

# 1) switch to tty2 (baked autologin root rescue shell): Ctrl+Alt+F2
press(['ctrl','alt','f2']); time.sleep(3)
press(['ret']); time.sleep(1)   # nudge the login/prompt

# 2) bootstrap one-liner: mount II_PAYLOAD ro, run the payload, (it powers off).
#    Kept SHORT + ASCII so QMP keystroke typing is robust (the payload itself
#    carries all the real logic; this only launches it).
line = ("mkdir -p /mnt/iismoke; "
        "mount -o ro /dev/disk/by-label/II_PAYLOAD /mnt/iismoke; "
        "bash /mnt/iismoke/ii-smoke-run.sh\n")
typ(line)
PY
}

step "phase 2/2 — functional battery (doctor · qs-load · pack round-trip · revert-all)"
info "waiting 20s for the session to settle, then driving tty2…"
sleep 20
_send_keys || warn "QMP keystroke injection reported an error (continuing to poll the result disk)"

# Poll: the payload powers the VM off when done. Wait for that (or FULL_TIMEOUT).
BATT_ELAPSED=0
while (( BATT_ELAPSED < FULL_TIMEOUT )); do
  sleep 15; BATT_ELAPSED=$((BATT_ELAPSED + 15))
  if ! kill -0 "$QPID" 2>/dev/null; then
    info "guest powered off at ${BATT_ELAPSED}s — reading verdict"
    break
  fi
  (( BATT_ELAPSED % 60 == 0 )) && info "${BATT_ELAPSED}s: battery running in-guest…"
done
if kill -0 "$QPID" 2>/dev/null; then
  kill "$QPID" 2>/dev/null; sleep 2
  warn "battery VM still running at ${FULL_TIMEOUT}s — forced off; verdict may be incomplete"
fi
QPID=""

# ── read the verdict + logs the in-guest payload stamped onto II_RESULT ──────
verdict=""
if command -v mcopy >/dev/null; then
  mcopy -i "$RESULT_IMG" ::result "$T/result.txt" 2>/dev/null && verdict="$(cat "$T/result.txt" 2>/dev/null)"
  mcopy -i "$RESULT_IMG" ::ii-smoke-run.log  "$T/g-root.log" 2>/dev/null || true
  mcopy -i "$RESULT_IMG" ::ii-smoke-user.log "$T/g-user.log" 2>/dev/null || true
else
  _rm=$(mktemp -d)
  if mount -o loop "$RESULT_IMG" "$_rm" 2>/dev/null || sudo mount -o loop "$RESULT_IMG" "$_rm"; then
    verdict="$(cat "$_rm/result" 2>/dev/null || true)"
    cp -f "$_rm"/*.log "$T/" 2>/dev/null || true
    umount "$_rm" 2>/dev/null || sudo umount "$_rm"
  fi
  rmdir "$_rm" 2>/dev/null || true
fi

# On failure, surface the guest logs so the failing stage + its output is visible.
if [[ "$verdict" != OK* ]]; then
  [[ -f "$T/g-user.log" ]] && { info "tail of in-guest (liveuser) log:"; tail -n 40 "$T/g-user.log" | sed 's/^/    guest| /' >&2; }
  [[ -f "$T/g-root.log" ]] && { info "tail of in-guest (root) log:";     tail -n 15 "$T/g-root.log" | sed 's/^/    guest| /' >&2; }
  die "functional battery FAILED — verdict: ${verdict:-<none: the in-guest payload never stamped a result; check that tty2 autologin + the II_PAYLOAD disk mounted, and see the logs above>}"
fi

ok "functional battery PASSED (doctor · qs-load · pack round-trip · revert-all idempotency)"
ok "smoke --full PASSED"
