#!/usr/bin/env bash
# install-smoke — unattended INSTALL→BOOT smoke of the newest out/*.iso (TEST-01,
# #80). The plain `smoke.sh` only boots the LIVE ISO; the entire Calamares
# install → first installed boot path is otherwise exercised only by the
# maintainer. Every install-time regression in this project's audit (SEC-01 tty2
# leak, INST-01 fizsh login break, INST-02/03, REV-01/02) would have been caught
# by an automated install smoke. This is it.
#
#   install-smoke.sh [--timeout SECONDS] [--keep-disk] [--disk PATH]
#   (invoked as `just smoke --installed`)
#
# Two phases against a throwaway qcow2 scratch disk:
#
#   Phase 1 — unattended install. Boot the live ISO with `ii_autoinstall` on the
#   kernel cmdline plus two small labelled vfat helper disks:
#     II_SEED (ro)  — a scripted/unattended Calamares config tree
#                            (erase-disk auto-partition, preset user/host/pw)
#     II_RESULT      (rw)  — where the in-VM ii-autoinstall stamps its verdict
#   The live-only execs.lua hook sees `ii_autoinstall`, runs ii-autoinstall,
#   which installs headlessly (Calamares → ii-post-install → ii-verify) and
#   powers the VM off. We then read II_RESULT/result: it MUST be "OK" (Calamares
#   exited 0, which means the shellprocess@verify-install ii-verify gate passed —
#   it exits non-zero to abort the install on a broken target).
#
#   Phase 2 — boot the installed disk. Boot the resulting qcow2 with NO ISO and
#   re-run the same QMP framebuffer colour probe smoke.sh uses: the installed
#   system must reach a rich graphical session (greetd → Hyprland → Quickshell).
#   A text fallback (a broken login shell — the INST-01 class — drops to agetty,
#   or greetd never starts) yields almost no distinct colours and FAILS.
#
# Requires hardware virtualization (KVM). Like smoke.sh, the graphical probe
# boots a full UEFI system into a Hyprland session, which never completes in time
# under TCG software emulation — and Phase 1 runs an actual disk install on top,
# which is far heavier still. So with no writable /dev/kvm this FAILS FAST with a
# clear message (CI-03 stance) instead of hanging to a misleading timeout. Set
# SMOKE_ALLOW_TCG=1 to force the slow TCG path with eyes open.
#
# NOTE for the maintainer: this is intended to run on a KVM-capable host (your
# box, or a KVM-enabled CI runner — release.yml already grants the smoke step
# /dev/kvm). The static gate (`just prepare && just validate`) does NOT build an
# ISO, so it cannot run this end to end; it only syntax/lint-checks the scripts
# and asserts the wiring. Build first: `just build`, then `just smoke --installed`.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require qemu-system-x86_64 qemu-img python3 mkfs.vfat

TIMEOUT=600          # whole-run wall clock for the install phase (heavy)
BOOT_TIMEOUT=300     # graphical-session probe for the installed boot phase
KEEP_DISK=false
DISK=""
while (( $# )); do
  case "$1" in
    --timeout)   TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --keep-disk) KEEP_DISK=true; shift ;;
    --disk)      DISK="${2:?--disk needs a path}"; shift 2 ;;
    --installed) shift ;;   # accepted so `just smoke --installed` routes here
    *) die "unknown option: $1" ;;
  esac
done

shopt -s nullglob; _isos=("$OUT"/*.iso); shopt -u nullglob
(( ${#_isos[@]} > 0 )) || die "no ISO in $OUT — just build"
ISO="$(ls -t "$OUT"/*.iso | head -1)"

# ── OVMF firmware (same lookup as smoke.sh / vm.sh) ─────────────────────────
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

# ── KVM gate (CI-03) — decided before any tempdir/trap so an early die is clean ─
KVM_ARGS=()
if [[ -w /dev/kvm ]]; then
  KVM_ARGS=( -enable-kvm -cpu host )
elif [[ -n "${SMOKE_ALLOW_TCG:-}" ]]; then
  warn "KVM required for the install smoke, but SMOKE_ALLOW_TCG is set — using TCG software emulation (very slow; a real install+boot will almost certainly exceed the timeouts)"
else
  die "KVM required for the install smoke: /dev/kvm is absent or not writable. This boots a full UEFI ISO, runs a real Calamares disk install into a graphical Hyprland session, then boots the installed disk and counts framebuffer colours — none of which finishes in time under TCG emulation, so the run would hang to a misleading timeout rather than fail here. Run on a KVM-capable host/runner (kvm group + writable /dev/kvm), or set SMOKE_ALLOW_TCG=1 to force the slow TCG path with eyes open."
fi

T=$(mktemp -d)
QPID=""
SELPID=""
trap 'kill "$QPID" "$SELPID" 2>/dev/null; rm -rf "$T"' EXIT

DISK="${DISK:-$T/install-disk.qcow2}"
$KEEP_DISK && DISK="$OUT/install-smoke-disk.qcow2"
qemu-img create -f qcow2 "$DISK" 40G >/dev/null
ok "scratch disk: $DISK (40G)"

# ── build the unattended Calamares seed (II_SEED) ────────────────────
# A minimal vfat image carrying a calamares/ tree that overrides the baked
# config to (a) erase + auto-partition the scratch disk with NO prompts and
# (b) preset the user/hostname/password so the `users` GUI screen never blocks.
# The in-VM ii-autoinstall overlays this onto /etc/calamares before running
# `calamares -d`. Everything else (mount/unpackfs/bootloader/post-install/verify
# sequence) is inherited from the baked settings.conf — we only swap the GUI
# `show:` phase for a fully automated one.
SEED_DIR="$T/seed"; mkdir -p "$SEED_DIR/calamares/modules"

# settings.conf: drop the interactive `show:` screens; keep the full `exec:`
# sequence verbatim (it is what actually installs + runs ii-post-install +
# ii-verify). The instances:/branding/flags are copied from the live config by
# ii-autoinstall, so we only need the sequence override here.
SMOKE_USER="smoketest"
SMOKE_HOST="ii-smoke"
SMOKE_PASS="smoke1234"

cat > "$SEED_DIR/calamares/settings.conf" <<'YAML'
# UNATTENDED install-smoke override (TEST-01). Overlaid onto /etc/calamares by
# ii-autoinstall; instances:/branding/prompt flags come from the live config.
---
modules-search: [local, /usr/lib/calamares/modules]

instances:
  - id:     copy-kernel
    module: shellprocess
    config: shellprocess-copy-kernel.conf
  - id:     finish-boot
    module: shellprocess
    config: shellprocess-finish-boot.conf
  - id:     post-install
    module: shellprocess
    config: shellprocess-post-install.conf
  - id:     verify-install
    module: shellprocess
    config: shellprocess-verify-install.conf

sequence:
  - exec:
    - partition
    - mount
    - unpackfs
    - machineid
    - fstab
    - locale
    - keyboard
    - localecfg
    - users
    - networkcfg
    - hwclock
    - services-systemd
    - shellprocess@copy-kernel
    - bootloader
    - shellprocess@finish-boot
    - shellprocess@post-install
    - shellprocess@verify-install
    - umount

branding: illogical-impulse

prompt-install:               false
dont-chroot:                  false
oem-setup:                    false
disable-cancel:               true
disable-cancel-during-exec:   true
hide-back-and-next-during-exec: true
quit-at-end:                  true
YAML

# partition.conf override: erase the (single) scratch disk, automatically.
# `initialPartitioningChoice: erase` + no manual partitioning = zero prompts.
cat > "$SEED_DIR/calamares/modules/partition.conf" <<'YAML'
# UNATTENDED erase-disk auto-partition for the install smoke (TEST-01).
---
defaultPartitionTableType: gpt
efi:
    mountPoint:      "/boot/efi"
    recommendedSize: 1GiB
    minimumSize:     512MiB
    label:           "EFI"
userSwapChoices:
  - none
initialSwapChoice: none
luksGeneration: luks2
drawNestedPartitions:      false
alwaysShowPartitionLabels: true
allowManualPartitioning:   false
initialPartitioningChoice: erase
YAML

# users.conf override: preset the account so the `users` module needs no GUI
# input. Keeps INST-01's fish shell (a regression to fizsh would break the
# installed login the Phase-2 probe then catches). autologin so Phase 2 reaches
# the session without a password prompt at greetd.
cat > "$SEED_DIR/calamares/modules/users.conf" <<YAML
# UNATTENDED preset account for the install smoke (TEST-01).
---
defaultGroups:
  - { name: users,   must_exist: false, system: false }
  - { name: lp,      must_exist: false, system: false }
  - { name: video,   must_exist: false, system: false }
  - { name: network, must_exist: false, system: false }
  - { name: storage, must_exist: false, system: false }
  - { name: wheel,   must_exist: false, system: false }
  - { name: audio,   must_exist: false, system: false }
  - { name: input,   must_exist: false, system: false }
sudoersGroup: wheel
setRootPassword: true
doReusePassword: true
doAutologin: true
userShell: /usr/bin/fish
passwordRequirements:
  minLength: 4
  maxLength: -1
# Preset answers so no GUI screen is needed.
fullName: "Smoke Test"
loginName: "$SMOKE_USER"
hostname: "$SMOKE_HOST"
password: "$SMOKE_PASS"
YAML

# Pack the seed into a small labelled vfat image.
SEED_IMG="$T/seed.img"
truncate -s 16M "$SEED_IMG"
mkfs.vfat -n II_SEED "$SEED_IMG" >/dev/null
# Copy the tree in with mtools if available, else a loopback mount (needs root).
if command -v mcopy >/dev/null; then
  ( cd "$SEED_DIR" && mcopy -i "$SEED_IMG" -s calamares :: )
else
  _sm=$(mktemp -d)
  if mount -o loop "$SEED_IMG" "$_sm" 2>/dev/null || sudo mount -o loop "$SEED_IMG" "$_sm"; then
    cp -a "$SEED_DIR/calamares" "$_sm/" || sudo cp -a "$SEED_DIR/calamares" "$_sm/"
    sync; umount "$_sm" 2>/dev/null || sudo umount "$_sm"
  else
    rmdir "$_sm"; die "cannot populate the seed vfat (install mtools, or run where loopback mount is allowed)"
  fi
  rmdir "$_sm" 2>/dev/null || true
fi

# The writable result disk the in-VM ii-autoinstall stamps its verdict onto.
RESULT_IMG="$T/result.img"
truncate -s 16M "$RESULT_IMG"
mkfs.vfat -n II_RESULT "$RESULT_IMG" >/dev/null
ok "unattended Calamares seed built (user=$SMOKE_USER host=$SMOKE_HOST)"

# ── shared: probe the framebuffer over QMP → count distinct colours ─────────
_probe() {
  python3 - "$1" "$2" <<'PY'
import json, socket, sys, time
sock_path, dump_path = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock_path); f = s.makefile("rw")
json.loads(f.readline())
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
    if img.readline().strip() != b"P6": print(0); sys.exit(0)
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

# Select the dedicated "Unattended install" systemd-boot entry (sort-key 05,
# carrying `ii_autoinstall`) by QMP keystrokes during the 5s menu timeout. The
# live loader.conf defaults to entry 01 with `timeout 5`; from the highlighted
# default we send `down` to reach 05, then `ret`. We resend a few times across
# the menu window so a slightly-late firmware handoff still lands the selection.
_select_autoinstall_entry() {
  python3 - "$T/qmp1.sock" <<'PY'
import json, socket, sys, time
sock_path = sys.argv[1]
# Wait for the QMP socket, then for the firmware to render the boot menu.
for _ in range(60):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(sock_path); break
    except OSError:
        time.sleep(1)
else:
    sys.exit(0)
f = s.makefile("rw"); json.loads(f.readline())
def cmd(c, **a):
    f.write(json.dumps({"execute": c, **({"arguments": a} if a else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd("qmp_capabilities")
def key(k):
    cmd("send-key", keys=[{"type": "qcode", "data": k}])
# loader.conf has `timeout 5`, so the menu auto-boots the default (entry 01)
# 5s after it appears. ANY keypress in systemd-boot cancels that countdown, so
# we must press a key BEFORE the timeout elapses. The QMP socket only exists
# once QEMU is up and OVMF still needs a few seconds to reach the menu, so we
# can't know exactly when the menu draws — instead we bombard `down` for ~12s
# from connect: an early stray press is harmless (the menu isn't up yet / it
# just moves the highlight), and once the menu is up the presses both cancel
# the auto-boot AND walk the highlight down to the autoinstall entry (sort-key
# 05). We then send several `ret`s to commit. We over-press `down` (capped by
# systemd-boot at the last entry) so we reliably land on 05 regardless of how
# many presses the firmware ate before the menu existed.
for _ in range(40):          # ~12s of nudging the highlight to the bottom entry
    key("down"); time.sleep(0.3)
for _ in range(3):           # commit; resend in case the first ret raced the draw
    key("ret"); time.sleep(2.0)
PY
}

# ═════════════════════════ PHASE 1 — unattended install ════════════════════
step "phase 1/2 — unattended install of $(basename "$ISO") (timeout ${TIMEOUT}s)"
cp "$OVMF_VARS_SRC" "$T/vars1.fd"
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -machine q35 -m 4096 -smp 4 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$T/vars1.fd" \
  -cdrom "$ISO" \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -drive "file=$SEED_IMG,if=virtio,format=raw,media=disk" \
  -drive "file=$RESULT_IMG,if=virtio,format=raw,media=disk" \
  -device virtio-vga \
  -display none \
  -qmp "unix:$T/qmp1.sock,server,nowait" \
  -nic none &
QPID=$!

# Drive the boot-menu selection in the background while the VM comes up.
_select_autoinstall_entry &
SELPID=$!

ELAPSED=0
INSTALL_OK=false
while (( ELAPSED < TIMEOUT )); do
  sleep 15; ELAPSED=$((ELAPSED + 15))
  if ! kill -0 "$QPID" 2>/dev/null; then
    info "VM powered off at ${ELAPSED}s — reading install verdict"
    break
  fi
  (( ELAPSED % 60 == 0 )) && info "${ELAPSED}s: install in progress…"
done
# Make sure the VM is down before we read the result disk back.
if kill -0 "$QPID" 2>/dev/null; then
  kill "$QPID" 2>/dev/null; sleep 2
  warn "install VM still running at ${TIMEOUT}s — forced off; verdict may be incomplete"
fi
QPID=""

# Read the verdict the in-VM ii-autoinstall stamped onto II_RESULT.
RES_MNT="$T/resmnt"; mkdir -p "$RES_MNT"
verdict=""
if command -v mcopy >/dev/null; then
  mcopy -i "$RESULT_IMG" ::result "$T/result.txt" 2>/dev/null && verdict="$(cat "$T/result.txt" 2>/dev/null)"
  mcopy -i "$RESULT_IMG" ::ii-autoinstall.log "$T/ii-autoinstall.log" 2>/dev/null || true
  mcopy -i "$RESULT_IMG" ::calamares-run.log  "$T/calamares-run.log"  2>/dev/null || true
else
  if mount -o loop "$RESULT_IMG" "$RES_MNT" 2>/dev/null || sudo mount -o loop "$RESULT_IMG" "$RES_MNT"; then
    verdict="$(cat "$RES_MNT/result" 2>/dev/null || true)"
    cp -f "$RES_MNT"/*.log "$T/" 2>/dev/null || true
    umount "$RES_MNT" 2>/dev/null || sudo umount "$RES_MNT"
  fi
fi
[[ -f "$T/calamares-run.log" ]] && { info "tail of Calamares run log:"; tail -n 20 "$T/calamares-run.log" | sed 's/^/    cala| /' >&2; }

if [[ "$verdict" == OK* ]]; then
  ok "install verdict: OK (Calamares + ii-verify green)"
  INSTALL_OK=true
else
  die "install FAILED — verdict: ${verdict:-<none: ii-autoinstall never stamped a result; check that the ISO carries the ii_autoinstall boot path and ii-autoinstall helper>}"
fi
$INSTALL_OK || die "install phase did not succeed"

# ═════════════════════════ PHASE 2 — boot the installed disk ════════════════
step "phase 2/2 — boot the installed system (timeout ${BOOT_TIMEOUT}s)"
cp "$OVMF_VARS_SRC" "$T/vars2.fd"
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -machine q35 -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$T/vars2.fd" \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -device virtio-vga \
  -display none \
  -qmp "unix:$T/qmp2.sock,server,nowait" \
  -nic none &
QPID=$!

ELAPSED=0
BEST=0
while (( ELAPSED < BOOT_TIMEOUT )); do
  sleep 30; ELAPSED=$((ELAPSED + 30))
  kill -0 "$QPID" 2>/dev/null || die "installed-system VM died at ${ELAPSED}s (no bootloader? broken initramfs? — INST-02/03 class)"
  N=$(_probe "$T/qmp2.sock" "$T/dump2.ppm" 2>/dev/null || echo 0)
  (( N > BEST )) && BEST=$N
  info "${ELAPSED}s: $N distinct colors on screen"
  if (( N >= 16 )); then
    ok "installed system reached a graphical session (${N} colors at ${ELAPSED}s)"
    ok "INSTALL→BOOT smoke PASSED"
    exit 0
  fi
done
die "installed system never reached a graphical session within ${BOOT_TIMEOUT}s (best probe: $BEST colors — broken login shell (INST-01 class), greetd down, or text fallback)"
