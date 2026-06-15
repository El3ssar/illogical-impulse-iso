#!/usr/bin/env bash
# validate — static audit on build/ (no root, no network). Every check here
# encodes a real failure mode; see CLAUDE.md §"Historic bugs" before pruning.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

AIROOTFS="$BUILD/airootfs"
PROFILEDEF="$BUILD/profiledef.sh"
PKGLIST="$BUILD/packages.x86_64"
SETTINGS="$AIROOTFS/etc/calamares/settings.conf"
PRETTY_NAME="$(tget distro.pretty_name)"
PASS=0 FAIL=0 WARNS=0
fails=() warns=()
_v_ok()   { ok "$*";   PASS=$((PASS+1)); }
_v_warn() { warn "$*"; WARNS=$((WARNS+1)); warns+=("$*"); }
_v_fail() { printf '   %sFAIL%s %s\n' "$C_R" "$C_0" "$*" >&2
            FAIL=$((FAIL+1)); fails+=("$*"); }

[[ -f "$PROFILEDEF" ]] || die "profiledef.sh missing — just prepare first"
[[ -d "$AIROOTFS"   ]] || die "airootfs/ missing — just prepare first"

step "profiledef"
if (
  set +u
  declare -A file_permissions
  declare -a bootmodes buildmodes airootfs_image_tool_options bootstrap_tarball_compression
  source "$PROFILEDEF" 2>/dev/null
); then _v_ok "sources cleanly"; else _v_fail "shell syntax error"; fi

set +u
declare -A file_permissions
declare -a bootmodes buildmodes airootfs_image_tool_options bootstrap_tarball_compression
# shellcheck disable=SC1090
source "$PROFILEDEF"
set -u
for v in iso_name iso_label iso_publisher; do
  [[ -n "${!v:-}" ]] && _v_ok "$v = ${!v}" || _v_fail "$v not set"
done
for bm in "${bootmodes[@]}"; do
  [[ "$bm" == "uefi.systemd-boot" ]] || _v_fail "bootmodes contains '$bm' (only uefi.systemd-boot)"
done
fp_miss=0
for p in "${!file_permissions[@]}"; do
  [[ -e "$AIROOTFS$p" ]] || { _v_fail "file_permissions[] dangling: $p"; fp_miss=$((fp_miss+1)); }
done
(( fp_miss == 0 )) && _v_ok "${#file_permissions[@]} file_permissions[] paths exist"

step "packages.x86_64"
need=(linux linux-firmware mkinitcpio mkinitcpio-archiso squashfs-tools base
      calamares kpmcore polkit dbus-broker
      efibootmgr intel-ucode amd-ucode
      dosfstools e2fsprogs btrfs-progs gptfdisk parted cryptsetup
      greetd greetd-agreety hyprland wayland xorg-xwayland fastfetch zram-generator)
miss=()
for p in "${need[@]}"; do
  grep -Eq "^\s*${p}\s*$" "$PKGLIST" || miss+=("$p")
done
(( ${#miss[@]} == 0 )) && _v_ok "$(grep -Ecv '^\s*(#|$)' "$PKGLIST") packages, all critical present" \
                       || _v_fail "missing critical: ${miss[*]}"

step "airootfs structure"
for f in etc/os-release etc/issue etc/motd \
         etc/fastfetch/config.jsonc "etc/$DISTRO_ID/logo.txt" "etc/$DISTRO_ID/release" \
         etc/passwd etc/shadow etc/group etc/gshadow etc/hostname \
         etc/locale.conf etc/locale.gen etc/pacman.conf \
         etc/sudoers.d/10-wheel-nopasswd \
         etc/greetd/config.toml etc/greetd/config.toml.installed.template \
         etc/mkinitcpio.conf.d/archiso.conf \
         etc/tmpfiles.d/greetd-home.conf \
         etc/systemd/system/getty@tty2.service.d/autologin.conf \
         etc/systemd/system/greetd.service.d/capture-logs.conf \
         root/customize_airootfs.sh \
         usr/local/bin/ii-session usr/local/bin/ii-ensure-venv \
         usr/local/bin/ii-launch-installer usr/local/bin/ii-live-welcome usr/local/bin/ii-post-install \
         usr/local/bin/ii-prepare-bootloader usr/local/bin/ii-finish-systemd-boot \
         usr/local/bin/ii-verify usr/local/bin/ii-build-wheelhouse \
         usr/local/bin/iictl \
         usr/share/illogical-impulse/welcome/shell.qml \
         usr/share/applications/illogical-impulse-welcome.desktop \
         root/nvidia-official.txt root/nvidia-aur.txt \
         usr/local/lib/ii/session-offline.sh \
         "usr/share/pixmaps/$DISTRO_ID.png" \
         usr/share/illogical-impulse/sdata/uv/requirements.txt; do
  [[ -e "$AIROOTFS/$f" ]] || _v_fail "missing: $f"
done
grep -q '^liveuser:' "$AIROOTFS/etc/passwd" \
  && _v_ok "liveuser in /etc/passwd" || _v_fail "liveuser missing from /etc/passwd"
[[ -d "$AIROOTFS/etc/skel/.config/quickshell" ]] \
  && _v_ok "etc/skel has quickshell config" || _v_fail "etc/skel missing quickshell config"
[[ -f "$AIROOTFS/etc/skel/.config/quickshell/ii/modules/common/widgets/shapes/material-shapes.js" ]] \
  && _v_ok "Quickshell shapes/ submodule present" \
  || _v_fail "shapes/material-shapes.js missing — git submodule update --init --recursive in $DOTS"

step "static OOB kitty-theme fallback"
SK="$AIROOTFS/etc/skel/.local/state/quickshell/user/generated/terminal/kitty-theme.conf"
if [[ -f "$SK" ]] && ! grep -qE '#\$term|#\$primary' "$SK"; then
  _v_ok "skel kitty-theme.conf present (no placeholders)"
elif [[ -f "$SK" ]]; then
  _v_fail "skel kitty-theme.conf has placeholders"
else
  _v_warn "no static kitty-theme.conf — first kitty open may show 'missing include'"
fi

step "themed self-contained bash (~/.bashrc)"
# ~/.bashrc is the UNOWNED home-root seam (upstream ships none). It must be a
# COMPLETE self-contained config that cats the upstream-generated palette from
# the EXACT generated/terminal/sequences.txt path — the literal grep below
# guards the bug-class where the path drops the terminal/ subdir and silently
# ships an uncolored shell (CLAUDE.md §"Historic bugs"; issue #11).
BRC="$AIROOTFS/etc/skel/.bashrc"
if [[ ! -s "$BRC" ]]; then
  _v_fail "/etc/skel/.bashrc missing or empty"
elif ! bash -n "$BRC" 2>/dev/null; then
  _v_fail "/etc/skel/.bashrc has a syntax error"
elif ! grep -qE '^[^#]*generated/terminal/sequences.txt' "$BRC"; then
  _v_fail "/etc/skel/.bashrc missing the guarded generated/terminal/sequences.txt cat (wrong/old path?)"
elif ! grep -q 'starship init bash' "$BRC"; then
  _v_fail "/etc/skel/.bashrc does not init starship"
else
  _v_ok "themed self-contained /etc/skel/.bashrc (guarded sequences cat + starship)"
fi

step "distro identity"
OSREL="$AIROOTFS/etc/os-release"
grep -q "^ID=$DISTRO_ID\$"                  "$OSREL" && _v_ok "ID=$DISTRO_ID"   || _v_fail "ID wrong"
grep -q '^ID_LIKE=arch$'                    "$OSREL" && _v_ok "ID_LIKE=arch"    || _v_fail "ID_LIKE wrong"
grep -q "^PRETTY_NAME=\"$PRETTY_NAME\""     "$OSREL" && _v_ok "PRETTY_NAME set" || _v_fail "PRETTY_NAME wrong"
logo=$(awk -F= '/^LOGO=/ {gsub(/"/,"",$2); print $2}' "$OSREL")
[[ -f "$AIROOTFS/usr/share/pixmaps/${logo}.png" ]] \
  && _v_ok "LOGO=$logo resolves" || _v_fail "LOGO=$logo but pixmap missing"

step "Calamares"
[[ -f "$SETTINGS" ]] || _v_fail "settings.conf missing"
if [[ -f "$SETTINGS" ]]; then
  branding=$(awk '/^branding:/ {print $2}' "$SETTINGS" | tr -d '"')
  bdir="$AIROOTFS/etc/calamares/branding/$branding"
  if [[ -d "$bdir" ]]; then
    _v_ok "branding: $branding"
    for a in branding.desc logo.png welcome.png slideshow.qml stylesheet.qss; do
      [[ -f "$bdir/$a" ]] || _v_fail "branding missing: $a"
    done
    grep -qE 'SidebarBackground' "$bdir/branding.desc" \
      && _v_ok "branding.desc has sidebar colors" \
      || _v_fail "branding.desc missing SidebarBackground"
  else
    _v_fail "branding dir missing: $bdir"
  fi
  while read -r inst; do
    [[ -z "$inst" ]] && continue
    cfg=$(awk -v i="$inst" '
      /^[[:space:]]*-[[:space:]]+id:/ { id=$3; gsub(/"/,"",id); next }
      /^[[:space:]]+config:/ && id==i { c=$2; gsub(/"/,"",c); print c; exit }
    ' "$SETTINGS")
    if [[ -z "$cfg" ]]; then
      _v_fail "shellprocess@$inst → no instances: mapping"
    else
      cfg_path="$AIROOTFS/etc/calamares/modules/$cfg"
      [[ -f "$cfg_path" ]] && _v_ok "shellprocess@$inst → $cfg" || _v_fail "shellprocess@$inst → $cfg (missing)"
      for s in $(grep -oE '/usr/local/bin/[a-zA-Z0-9_-]+' "$cfg_path" 2>/dev/null | sort -u); do
        [[ -f "$AIROOTFS$s" ]] || _v_fail "  $cfg script missing: $s"
      done
    fi
  done < <(grep -oE 'shellprocess@[a-z-]+' "$SETTINGS" | sed 's/shellprocess@//' | sort -u)

  uc="$AIROOTFS/etc/calamares/modules/unpackfs.conf"
  ! grep -qE '^\s*sourcefs:\s*"?squashfs"?' "$uc" \
    && _v_ok "unpackfs.conf: sourcefs is not 'squashfs'" \
    || _v_fail "unpackfs.conf: sourcefs: squashfs is wrong (install will crash)"
  bc="$AIROOTFS/etc/calamares/modules/bootloader.conf"
  grep -qE '^\s*efiBootLoader:\s*"?systemd-boot"?' "$bc" \
    && _v_ok "bootloader.conf: systemd-boot" || _v_fail "bootloader.conf not systemd-boot"
  grep -qE '^\s*installEFIFallback:\s*true' "$bc" \
    && _v_ok "bootloader.conf: EFI fallback enabled" \
    || _v_warn "bootloader.conf: no EFI fallback (VirtualBox installs may not boot)"
fi

step "batteries + nvidia auto-detect"
# No selection screen: defaults are baked. Spot-check that the flagship
# goodies actually made it into packages.x86_64.
for p in brave-bin vlc linux-lts onlyoffice-bin neovim docker snapper flatpak; do
  grep -Eq "^\s*${p}\s*$" "$PKGLIST" && _v_ok "baked: $p" || _v_fail "goodie missing from packages.x86_64: $p"
done
grep -Eq '^\s*mpv\s*$' "$PKGLIST" && _v_fail "mpv crept in (vlc is the shipped player)" || _v_ok "no mpv"
[[ -s "$AIROOTFS/root/nvidia-official.txt" ]] \
  && _v_ok "nvidia stash manifest staged ($(grep -c . "$AIROOTFS/root/nvidia-official.txt") official + $(grep -c . "$AIROOTFS/root/nvidia-aur.txt" 2>/dev/null || echo 0) AUR)" \
  || _v_warn "no nvidia manifest — NVIDIA machines fall back to nouveau"
grep -q 'NVSTASH' "$AIROOTFS/usr/local/bin/ii-post-install" \
  && _v_ok "ii-post-install has nvidia auto-detect" || _v_fail "ii-post-install missing nvidia block"

step "distro perks (iictl + welcome card)"
grep -q 'iictl welcome --auto' "$AIROOTFS/etc/skel/.config/hypr/custom/execs.lua" 2>/dev/null \
  && _v_ok "installed-user skel launches the welcome card" \
  || _v_fail "skel custom/execs.lua missing the welcome launcher"
# Strip comment lines first: ii-verify legitimately *documents* the iictl
# survive-path (iictl.d/ + ledger), so only a reference in real code (e.g.
# iictl added to the purge loop, or an rm of /usr/local/bin/iictl) is a bug.
grep -vE '^[[:space:]]*#' "$AIROOTFS/usr/local/bin/ii-verify" | grep -q 'iictl' \
  && _v_fail "ii-verify purges iictl — it must survive installs" \
  || _v_ok "iictl survives the post-install purge"
# Any *recursive* rm targeting the lib dir (or a survive-subpath like iictl.d/)
# is the bug — match -r/-R in either flag order and a trailing slash/subpath,
# not just the one historical line. The named-file `rm -f .../session-offline.sh`
# (no -r) and the `rmdir` cleanup are deliberately allowed. Comments stripped so
# ii-verify can still *document* the rule without tripping it.
grep -vE '^[[:space:]]*#' "$AIROOTFS/usr/local/bin/ii-verify" \
  | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+/usr/local/lib/ii' \
  && _v_fail "ii-verify recursively removes /usr/local/lib/ii — iictl.d/ + ledger must survive" \
  || _v_ok "ii-verify preserves /usr/local/lib/ii (iictl.d/ + ledger survive)"
grep -Eq '^\s*git\s*$' "$PKGLIST" \
  && _v_ok "git baked (paru + iictl update need it)" \
  || _v_fail "git missing from packages.x86_64"
grep -qE '^\s*- (netinstall|packages)\s*(#.*)?$' "$SETTINGS" \
  && _v_fail "settings.conf still references the removed selection flow" \
  || _v_ok "settings.conf has no selection-screen leftovers"

step "live mkinitcpio"
MK="$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf"
for h in base udev archiso block filesystems; do
  grep -E "^HOOKS=.*\\b${h}\\b" "$MK" >/dev/null \
    && _v_ok "HOOKS contains '$h'" || _v_fail "HOOKS missing '$h' — live ISO won't boot"
done
for h in archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs; do
  grep -E "^HOOKS=.*\\b${h}\\b" "$MK" >/dev/null \
    && _v_fail "HOOKS contains '$h' (needs nbd-client not in pacstrap)"
done

step "[$REPO_NAME] repo"
[[ -f "$BUILD/pacman.conf" ]] && grep -q "^\[$REPO_NAME\]" "$BUILD/pacman.conf" \
  && _v_ok "pacman.conf has [$REPO_NAME]" || _v_fail "pacman.conf missing [$REPO_NAME]"

step "efiboot loader entries"
ED="$BUILD/efiboot/loader/entries"
[[ -d "$ED" ]] && _v_ok "$(find "$ED" -maxdepth 1 -type f | wc -l) entries" \
               || _v_fail "efiboot/loader/entries/ missing"

step "runtime + chroot scripts syntax"
for sc in "$AIROOTFS/usr/local/bin/"ii-session \
          "$AIROOTFS/usr/local/bin/"ii-launch-installer \
          "$AIROOTFS/usr/local/bin/"iictl \
          "$AIROOTFS/usr/local/bin/"ii-post-install \
          "$AIROOTFS/usr/local/bin/"ii-prepare-bootloader \
          "$AIROOTFS/usr/local/bin/"ii-finish-systemd-boot \
          "$AIROOTFS/usr/local/bin/"ii-verify \
          "$AIROOTFS/root/"customize_airootfs.sh; do
  [[ -f "$sc" ]] || { _v_fail "missing: $sc"; continue; }
  [[ "$(head -c2 "$sc")" == "#!" ]] || _v_fail "no shebang: $(basename "$sc")"
  bash -n "$sc" 2>/dev/null && _v_ok "$(basename "$sc")" || _v_fail "$(basename "$sc") syntax error"
done

step "summary"
printf '   pass %s%d%s    warn %s%d%s    fail %s%d%s\n\n' \
  "$C_G" $PASS "$C_0" "$C_Y" $WARNS "$C_0" "$C_R" $FAIL "$C_0" >&2
if (( ${#fails[@]} > 0 )); then
  printf '%sFAILURES%s\n' "$C_R$C_B" "$C_0" >&2
  printf '   • %s\n' "${fails[@]}" >&2
fi
if (( ${#warns[@]} > 0 )); then
  printf '%sWARNINGS%s\n' "$C_Y$C_B" "$C_0" >&2
  printf '   • %s\n' "${warns[@]}" >&2
fi
(( FAIL == 0 ))
