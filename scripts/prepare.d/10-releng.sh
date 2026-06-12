# shellcheck shell=bash disable=SC2154
# 10-releng — wipe build/ and lay down the archiso releng baseline from the
# installed archiso package. We no longer vendor a frozen releng copy; the
# builder host/container pins the archiso version instead.

RELENG_SRC=/usr/share/archiso/configs/releng

step "releng baseline → build/"
[[ -d "$RELENG_SRC" ]] || die "$RELENG_SRC missing — install archiso (sudo pacman -S archiso)"
_wipe "$BUILD"
install -d "$BUILD"
rsync -a "$RELENG_SRC/" "$BUILD/"
chmod -R u+w "$BUILD"
# UEFI-only distro: BIOS bootloaders are dead weight (packages pruned in 40).
rm -rf "$BUILD/grub" "$BUILD/syslinux"
ok "archiso $(pacman -Q archiso 2>/dev/null | awk '{print $2}') baseline"

step "host pacman.conf (adds [$REPO_NAME])"
cp -f "$OVERLAY/pacman.conf" "$BUILD/pacman.conf"
ok "staged"
