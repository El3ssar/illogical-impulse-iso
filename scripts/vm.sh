#!/usr/bin/env bash
# vm — boot the newest out/*.iso in QEMU (UEFI, KVM, virtio GL).
#
#   vm.sh                boot the live ISO
#   vm.sh --disk         also attach out/vm-disk.qcow2 (created if missing)
#                        so a full Calamares install can be tested
#   vm.sh --installed    boot the INSTALLED system from the disk (no ISO)
#   vm.sh --fresh-disk   recreate the disk first
#   vm.sh --no-kvm       software emulation (slow; for odd hosts)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require qemu-system-x86_64 qemu-img

USE_DISK=false KVM=true INSTALLED=false
for a in "$@"; do
  case "$a" in
    --disk)       USE_DISK=true ;;
    --installed)  INSTALLED=true; USE_DISK=true ;;
    --fresh-disk) USE_DISK=true; rm -f "$OUT/vm-disk.qcow2" ;;
    --no-kvm)     KVM=false ;;
    *) die "unknown option: $a" ;;
  esac
done

ISO=""
if ! $INSTALLED; then
  shopt -s nullglob; _isos=("$OUT"/*.iso); shopt -u nullglob
  (( ${#_isos[@]} > 0 )) || die "no ISO in $OUT — run: just build"
  ISO="$(ls -t "$OUT"/*.iso | head -1)"
else
  [[ -f "$OUT/vm-disk.qcow2" ]] || die "no $OUT/vm-disk.qcow2 — install first: just vm --disk"
fi

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
         /usr/share/OVMF/x64/OVMF_CODE.4m.fd \
         /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
done
[[ -n "$OVMF_CODE" ]] || die "OVMF firmware not found — install edk2-ovmf"
OVMF_VARS_SRC="${OVMF_CODE/CODE/VARS}"
[[ -f "$OVMF_VARS_SRC" ]] || die "OVMF VARS template missing: $OVMF_VARS_SRC"
OVMF_VARS="$(mktemp --suffix=.fd)"
cp "$OVMF_VARS_SRC" "$OVMF_VARS"
trap 'rm -f "$OVMF_VARS"' EXIT

args=(
  -machine q35 -m 8192 -smp 4
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$OVMF_VARS"
  -device virtio-vga-gl -display gtk,gl=on
  -nic user,model=virtio-net-pci
)
# Fresh NVRAM every run — booting the installed disk works regardless
# because ii-finish-systemd-boot installs the EFI fallback (BOOT/BOOTX64.EFI).
$INSTALLED || args+=( -cdrom "$ISO" -boot d )
$KVM && args+=( -enable-kvm -cpu host )
if $USE_DISK; then
  [[ -f "$OUT/vm-disk.qcow2" ]] || qemu-img create -f qcow2 "$OUT/vm-disk.qcow2" 40G >/dev/null
  args+=( -drive "file=$OUT/vm-disk.qcow2,if=virtio,format=qcow2" )
fi

step "qemu ← $($INSTALLED && echo "vm-disk.qcow2 (installed system)" || basename "$ISO")"
exec qemu-system-x86_64 "${args[@]}"
