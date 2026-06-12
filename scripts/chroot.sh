#!/usr/bin/env bash
# Runs INSIDE the airootfs chroot during mkarchiso. Staged here by
# prepare.sh as /root/customize_airootfs.sh (the path mkarchiso looks for).
#
# Job: complete the live-ISO/installed-system bootstrap that can only happen
# inside a chroot (paru build, Python wheelhouse, liveuser home seed).
# Everything that can be expressed as a static file lives in overlay/airootfs/
# directly — this script does not write drop-ins anymore.

set -u

AUR_PKGLIST=/root/aur-packages.txt
BUILD_USER=aurbuilder
LOG=/var/log/customize_airootfs.log

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "==== customize_airootfs.sh — $(date -u +%FT%TZ) ===="

step() { printf '\n>> %s\n' "$*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

# Sanity: calamares must already be present (built by prebuild.sh, pulled via [ii-extra])
command -v calamares >/dev/null || die "calamares not installed — prebuild + [ii-extra] in pacman.conf is the only path"

# ── chroot keyring + build deps ─────────────────────────────────────────────
step "pacman keyring"
pacman-key --init
pacman-key --populate archlinux

step "chroot build deps (purged on install by post-install)"
# wheelhouse needs python build chain; paru needs base-devel; both need git
pacman -S --needed --noconfirm \
  git pkgconf cairo dbus ninja meson meson-python python base-devel \
  || die "build deps install failed"
pacman -Sy --noconfirm || echo "warn: pacman -Sy failed (no network in chroot?)"

# ── unprivileged user for makepkg ──────────────────────────────────────────
step "create $BUILD_USER"
useradd -m -s /bin/bash "$BUILD_USER"
echo "$BUILD_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aurbuilder
chmod 440 /etc/sudoers.d/aurbuilder
install -d -o "$BUILD_USER" -g "$BUILD_USER" "/home/$BUILD_USER/.config/paru"
cat > "/home/$BUILD_USER/.config/paru/paru.conf" <<'PARU'
[options]
BottomUp
SudoLoop
NewsOnUpgrade = false
PARU
chown -R "$BUILD_USER:$BUILD_USER" "/home/$BUILD_USER/.config"

asbuilder() { sudo -u "$BUILD_USER" bash -c "$*"; }

# ── paru (best-effort) ─────────────────────────────────────────────────────
step "build paru"
PARU_OK=0
asbuilder '
  set -e
  cd /tmp
  rm -rf paru
  git clone --depth=1 https://aur.archlinux.org/paru.git
  cd paru
  makepkg -si --noconfirm --skippgpcheck
' && PARU_OK=1
rm -rf /tmp/paru
(( PARU_OK )) || echo "warn: paru build failed — cosmetic AUR will be skipped"

# ── cosmetic AUR (fail-soft) ───────────────────────────────────────────────
if (( PARU_OK )) && [[ -s "$AUR_PKGLIST" ]]; then
  step "install cosmetic AUR from $AUR_PKGLIST"
  mapfile -t pkgs < <(grep -Ev '^\s*(#|$)' "$AUR_PKGLIST")
  for pkg in "${pkgs[@]}"; do
    asbuilder "paru -S --noconfirm --needed --sudoloop --mflags '--skippgpcheck' $pkg" \
      || echo "warn: $pkg failed (fail-soft)"
  done
fi

# ── NVIDIA driver stash ─────────────────────────────────────────────────────
# A tiny pacman repo (flat: db + files in ONE dir — pacman fetches
# $Server/$filename) that rides inside the squashfs and is copied to the
# target by unpackfs. ii-post-install detects NVIDIA hardware there and
# installs the right variant offline, then removes the stash.
# AUR variants (nvidia-580xx-*) were prebuilt on the host and staged here
# by mkiso.sh; we add the official ones + the full dependency closure.
step "NVIDIA driver stash → /usr/share/illogical-impulse/nvidia"
NVSTASH=/usr/share/illogical-impulse/nvidia
install -d "$NVSTASH"
# pacman -Sw drops detached .sig files next to the packages — repo-add must
# never see those (it chokes trying to parse them as packages).
_nv_pkgs() {
  nvpkgs=()
  local f
  shopt -s nullglob
  for f in "$NVSTASH"/*.pkg.tar.*; do
    [[ "$f" != *.sig ]] && nvpkgs+=("$f")
  done
  shopt -u nullglob
}
if [[ -s /root/nvidia-official.txt ]]; then
  _nv_pkgs
  if (( ${#nvpkgs[@]} > 0 )); then
    repo-add -q "$NVSTASH/ii-nvidia.db.tar.gz" "${nvpkgs[@]}"
  else
    repo-add -q "$NVSTASH/ii-nvidia.db.tar.gz"
  fi
  sed "/^\[core\]/i [ii-nvidia]\nSigLevel = Optional TrustAll\nServer = file://$NVSTASH" \
    /etc/pacman.conf > /etc/pacman-iibuild.conf
  pacman --config /etc/pacman-iibuild.conf -Sy --noconfirm || die "nvidia stash repo sync failed"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # per-package transactions: the two driver variants conflict
    pacman --config /etc/pacman-iibuild.conf -Sw --noconfirm --cachedir "$NVSTASH" "$p" \
      || die "nvidia stash: download failed for $p"
  done < <(cat /root/nvidia-official.txt /root/nvidia-aur.txt 2>/dev/null)
  _nv_pkgs
  repo-add -q "$NVSTASH/ii-nvidia.db.tar.gz" "${nvpkgs[@]}"
  # No detection data needed: supported-gpus.json no longer ships in any
  # nvidia package — ii-post-install classifies GPUs by PCI device id.
  rm -f /etc/pacman-iibuild.conf /var/lib/pacman/sync/ii-nvidia.db*
  echo "nvidia stash: ${#nvpkgs[@]} packages"
else
  echo "no nvidia manifest — skipping stash"
fi

# ── Python wheelhouse (offline first-boot install) ─────────────────────────
step "build offline Python wheelhouse → /usr/share/ii-python-wheels"
[[ -x /usr/local/bin/ii-build-wheelhouse ]] \
  || die "ii-build-wheelhouse missing in /usr/local/bin"
/usr/local/bin/ii-build-wheelhouse || die "wheelhouse build failed"

# ── /etc/skel: restore +x on scripts (mkarchiso strips perms) ──────────────
step "restore +x on /etc/skel scripts"
# mkarchiso copies airootfs via `cp -af --no-preserve=mode`, which clobbers
# +x. Walk every file in /etc/skel, restore +x where there's a shebang or a
# script-like extension. Without this, Quickshell helpers silently fail.
if [[ -d /etc/skel ]]; then
  while IFS= read -r f; do
    [[ "$(head -c2 "$f" 2>/dev/null)" == "#!" ]] && chmod 0755 "$f"
  done < <(find /etc/skel -type f 2>/dev/null)
  find /etc/skel -type f \
    \( -name '*.sh' -o -name '*.fish' -o -name '*.zsh' -o -name '*.bash' \
       -o -name '*.py' -o -name '*.desktop' \) \
    -exec chmod 0755 {} + 2>/dev/null || true
fi

# ── seed liveuser home from skel-upstream + skel-live ──────────────────────
step "seed /home/liveuser"
# liveuser gets upstream dotfiles + live-only overlays.
# Installed users get /etc/skel (= skel-upstream + overlay/skel) via Calamares.
install -d -o liveuser -g liveuser -m 0750 /home/liveuser
[[ -d /etc/skel-upstream ]] && cp -aT /etc/skel-upstream /home/liveuser
[[ -d /etc/skel-live     ]] && cp -aT /etc/skel-live     /home/liveuser
find /home/liveuser -type f \
  \( -name '*.desktop' -o -name '*.sh' -o -name '.xinitrc' \) \
  -exec chmod 0755 {} + 2>/dev/null || true
chown -R liveuser:liveuser /home/liveuser

# ── Quickshell venv for liveuser ───────────────────────────────────────────
# Color generation, kitty theming, etc. are NOT pre-rendered here. Upstream's
# Quickshell FirstRunExperience.qml does it on first Hyprland boot in a real
# session — we just make sure the venv exists.
step "liveuser venv from wheelhouse"
sudo -u liveuser env \
  HOME=/home/liveuser \
  XDG_CONFIG_HOME=/home/liveuser/.config \
  XDG_STATE_HOME=/home/liveuser/.local/state \
  XDG_CACHE_HOME=/home/liveuser/.cache \
  UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-/usr/share/uv/python}" \
  /usr/local/bin/ii-ensure-venv \
  || die "ii-ensure-venv failed for liveuser"
sudo -u liveuser /home/liveuser/.local/state/quickshell/.venv/bin/python \
  -c 'import materialyoucolor, PIL' \
  || die "liveuser venv missing Pillow / materialyoucolor"

# ── ydotool (USER service — no overlay equivalent) + vboxservice (optional) ─
step "user/optional services"
install -d /etc/systemd/user/default.target.wants
[[ -e /usr/lib/systemd/user/ydotool.service ]] \
  && ln -sf /usr/lib/systemd/user/ydotool.service \
            /etc/systemd/user/default.target.wants/ydotool.service
install -d /etc/systemd/system/multi-user.target.wants
[[ -e /usr/lib/systemd/system/vboxservice.service ]] \
  && ln -sf /usr/lib/systemd/system/vboxservice.service \
            /etc/systemd/system/multi-user.target.wants/vboxservice.service

# ── kernel + zram ──────────────────────────────────────────────────────────
echo 'i2c-dev' > /etc/modules-load.d/i2c-dev.conf
install -d /etc/kernel/cmdline.d
[[ -f /etc/kernel/install.conf ]] || cat > /etc/kernel/install.conf <<'KIC'
layout=bls
initrd_generator=mkinitcpio
KIC
echo 'loglevel=4 rootwait rw' > /etc/kernel/cmdline.d/illogical-impulse.conf

# ── microcode stash (mkarchiso wipes /boot/* after this script) ────────────
step "stash CPU microcode for ii-prepare-bootloader"
# intel-ucode / amd-ucode ship files directly in /boot with no /usr/share/
# fallback. mkarchiso wipes /boot after this script — without the stash the
# installed system gets no microcode loaded.
install -d -m 0755 /usr/share/illogical-impulse/boot-stash
for img in /boot/intel-ucode.img /boot/amd-ucode.img; do
  [[ -f "$img" ]] && install -m 0644 "$img" /usr/share/illogical-impulse/boot-stash/
done

# ── locale + ownership ─────────────────────────────────────────────────────
[[ -f /etc/locale.gen ]] && locale-gen 2>/dev/null || true
chown -R root:root /root
chmod 700 /root

# ── sanity gate — abort the ISO if anything required is missing ────────────
step "sanity gate"
for cmd in calamares greetd agreety Hyprland start-hyprland qs; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
for p in \
  /etc/os-release \
  /etc/fastfetch/config.jsonc \
  /etc/illogical-impulse/logo.txt \
  /usr/share/pixmaps/illogical-impulse.png \
  /etc/greetd/config.toml \
  /etc/greetd/config.toml.installed.template \
  /usr/local/bin/ii-session \
  /usr/local/bin/ii-ensure-venv \
  /usr/local/bin/ii-post-install \
  /usr/local/bin/ii-prepare-bootloader \
  /usr/local/bin/ii-finish-systemd-boot \
  /usr/local/bin/ii-verify \
  /usr/share/illogical-impulse/boot-stash \
  /home/liveuser/.config/hypr \
  "/home/liveuser/Desktop/Install Illogical Impulse.desktop"; do
  [[ -e "$p" ]] || die "missing: $p"
done

grep -q '^ID=illogical-impulse' /etc/os-release \
  || die "/etc/os-release does not identify as illogical-impulse"

# ── cleanup ────────────────────────────────────────────────────────────────
step "cleanup"
# The calamares package ships its own launcher entries ("Install System")
# that bypass ii-launch-installer's env wrapper and break under the live
# session — "Install Illogical Impulse" must be the only installer entry.
rm -f /usr/share/applications/calamares.desktop \
      /usr/share/applications/calamares-launch-oem.desktop
userdel -r "$BUILD_USER" 2>/dev/null || true
rm -f /etc/sudoers.d/aurbuilder
paru -Scc --noconfirm 2>/dev/null || true
pacman -Scc --noconfirm 2>/dev/null || true
rm -f /var/log/pacman.log
find /var/log/journal -type f -delete 2>/dev/null || true

echo ""
echo "==== customize_airootfs.sh done — $(date -u +%FT%TZ) ===="
