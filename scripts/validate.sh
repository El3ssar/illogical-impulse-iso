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

# Pillar-6 reversibility lint — the four structural checks not already inline
# below (skel-shadow collision, optional-list validity, PII guard, and the
# skel-upstream precondition). Sourced here, invoked as its own step further
# down; reuses the _v_* tallies above. Checks 2/3/5 of Pillar 6 already live
# inline in their own steps (see tools/lint-additive.sh header for the map).
# shellcheck source=../tools/lint-additive.sh
source "$TOOLS/lint-additive.sh"

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
  # SEC-01/SEC-02: the tty1 (releng baseline) and tty2 (our overlay) getty
  # passwordless-root autologin drop-ins are live-ISO-only. Each drop-in (dir or
  # file) MUST be in unpackfs.conf's exclude list AND removed by ii-post-install,
  # else every installed system ships passwordless root on Ctrl+Alt+F1/F2 (tty1
  # the moment greetd is disabled/removed).
  grep -qE '^\s*-\s+etc/systemd/system/getty@tty1\.service\.d' "$uc" \
    && _v_ok "unpackfs.conf: tty1 root autologin excluded from install (SEC-02)" \
    || _v_fail "unpackfs.conf: tty1 passwordless-root autologin NOT excluded — leaks onto installed systems (SEC-02)"
  grep -qE '^\s*-\s+etc/systemd/system/getty@tty2\.service\.d' "$uc" \
    && _v_ok "unpackfs.conf: tty2 root autologin excluded from install (SEC-01)" \
    || _v_fail "unpackfs.conf: tty2 passwordless-root autologin NOT excluded — leaks onto installed systems (SEC-01)"
  grep -q 'getty@tty1.service.d/autologin.conf' "$AIROOTFS/usr/local/bin/ii-post-install" \
    && _v_ok "ii-post-install strips tty1 root autologin (defense-in-depth, SEC-02)" \
    || _v_fail "ii-post-install missing tty1 autologin removal (SEC-02)"
  grep -q 'getty@tty2.service.d/autologin.conf' "$AIROOTFS/usr/local/bin/ii-post-install" \
    && _v_ok "ii-post-install strips tty2 root autologin (defense-in-depth, SEC-01)" \
    || _v_fail "ii-post-install missing tty2 autologin removal (SEC-01)"
  bc="$AIROOTFS/etc/calamares/modules/bootloader.conf"
  grep -qE '^\s*efiBootLoader:\s*"?systemd-boot"?' "$bc" \
    && _v_ok "bootloader.conf: systemd-boot" || _v_fail "bootloader.conf not systemd-boot"
  grep -qE '^\s*installEFIFallback:\s*true' "$bc" \
    && _v_ok "bootloader.conf: EFI fallback enabled" \
    || _v_warn "bootloader.conf: no EFI fallback (VirtualBox installs may not boot)"
  # INST-01: the new user's login shell (users.conf userShell) must be a package
  # that actually ships, or every login (bare TTY, su -, ssh, chsh tools) breaks.
  # fizsh leaked in from a hypothetical GUIDE recipe and was in no package list.
  # Static heuristic mirroring the shellprocess-script-exists guard: derive the
  # owning package from the shell binary basename (with the known nu→nushell map)
  # and assert it is in packages.x86_64.
  usr="$AIROOTFS/etc/calamares/modules/users.conf"
  ushell=$(awk '/^[[:space:]]*userShell:/{print $2; exit}' "$usr" 2>/dev/null | tr -d '"')
  if [[ -z "$ushell" ]]; then
    _v_fail "users.conf: no userShell set (INST-01)"
  else
    sbin="${ushell##*/}"
    case "$sbin" in nu) spkg=nushell ;; *) spkg="$sbin" ;; esac
    grep -Eq "^\s*${spkg}\s*$" "$PKGLIST" \
      && _v_ok "users.conf: login shell '$ushell' ships (pkg $spkg in packages.x86_64) (INST-01)" \
      || _v_fail "users.conf: login shell '$ushell' has no package ($spkg) in packages.x86_64 — installed user's login breaks (INST-01)"
  fi
fi

step "batteries + nvidia auto-detect"
# No selection screen: defaults are baked. Spot-check that the flagship
# goodies actually made it into packages.x86_64.
for p in brave-bin vlc linux-lts onlyoffice-bin neovim docker snapper flatpak \
         github-cli git-delta direnv just mise distrobox noto-fonts-emoji \
         cups cups-pdf bluez-utils sane simple-scan; do
  grep -Eq "^\s*${p}\s*$" "$PKGLIST" && _v_ok "baked: $p" || _v_fail "goodie missing from packages.x86_64: $p"
done
# jq / go-yq / ttf-jetbrains-mono-nerd are upstream PKGBUILD depends (scraped
# into packages.x86_64 by resolve-deps.py), NOT goodies.list lines. Asserting
# them here would test the wrong layer, so they are deliberately omitted.
grep -Eq '^\s*mpv\s*$' "$PKGLIST" && _v_fail "mpv crept in (vlc is the shipped player)" || _v_ok "no mpv"
[[ -s "$AIROOTFS/root/nvidia-official.txt" ]] \
  && _v_ok "nvidia stash manifest staged ($(grep -c . "$AIROOTFS/root/nvidia-official.txt") official + $(grep -c . "$AIROOTFS/root/nvidia-aur.txt" 2>/dev/null || echo 0) AUR)" \
  || _v_warn "no nvidia manifest — NVIDIA machines fall back to nouveau"
grep -q 'NVSTASH' "$AIROOTFS/usr/local/bin/ii-post-install" \
  && _v_ok "ii-post-install has nvidia auto-detect" || _v_fail "ii-post-install missing nvidia block"
grep -q 'cups.socket' "$AIROOTFS/usr/local/bin/ii-post-install" \
  && _v_ok "ii-post-install enables cups.socket" || _v_fail "ii-post-install missing cups.socket enable"

step "bake/fetch budget governor"
# PROPOSAL §4 Pillar 7 / §18: the ISO is already ~5.8 GB — over GitHub's 2 GiB
# release-asset cap (it ships via SourceForge), so every bake compounds the
# distribution problem. Only small + universal things may be BAKED into
# goodies.list; heavy/opinionated stacks belong in the FETCHED-ONLINE tier
# (installed on demand over the network via `iictl pack`/`iictl pkg` — never
# baked, never stashed into the image).
# This is a SOFT gate: non-fatal WARNs (never _v_fail) that nudge a NEW
# heavy/non-universal goodies entry toward the right tier; the sanctioned
# flagships are explicitly allowlisted so the stock list stays silent. Static,
# no root, no network — reads the source manifest, not build/.
GOODIES="$PACKAGES/goodies.list"
# Sanctioned baked set (flagships + small universal) as of this writing. These
# are deliberate bakes and must NOT warn. To bless a genuinely-small universal
# addition, add it here; to add a heavy one, move it to packages/optional.
_budget_allow=(
  btop eza bat ripgrep ripgrep-all repgrep fd fzf skim zellij 7zip lazygit
  brave-bin vlc kdeconnect strawberry linux-lts linux-lts-headers
  onlyoffice-bin inkscape gimp obs-studio
  base-devel git neovim code cursor-bin rustup uv docker docker-compose podman claude-code
  github-cli git-delta direnv just mise distrobox noto-fonts-emoji
  cups cups-pdf bluez-utils sane simple-scan snapper snap-pac flatpak
)
declare -A _budget_ok=()
for _b in "${_budget_allow[@]}"; do _budget_ok["$_b"]=1; done
# Heavy/non-universal name patterns (heuristic, non-exhaustive, dependency-free):
# language toolchains, big GUI suites, GPU/ML stacks, VMs, full desktops,
# texlive. The allowlist above is the authority for what may be baked; this only
# flags NEW heavy additions. Extend either list as the batteries set evolves.
_budget_heavy='^(steam|lutris|wine|wine-staging|winetricks|heroic-games-launcher.*|blender|kdenlive|shotcut|handbrake.*|darktable|krita|audacity|rawtherapee|scribus|davinci.*|olive.*|natron|freecad|openscad|qgis|godot|android-studio|intellij.*|pycharm.*|clion.*|webstorm.*|datagrip.*|rider.*|eclipse|netbeans|unityhub.*|libreoffice.*|wps-office.*|thunderbird|firefox|chromium|google-chrome.*|vivaldi.*|opera.*|microsoft-edge.*|nodejs|npm|deno|bun|ruby|go|golang|jdk.*|jre.*|.*-jdk.*|.*-jre.*|openjdk.*|java-.*|dotnet.*|mono|php|julia.*|texlive.*|.*-cuda.*|cuda.*|cudnn.*|rocm.*|hip-.*|tensorflow.*|pytorch.*|python-torch.*|python-tensorflow.*|opencv.*|qemu-full|qemu-desktop|virtualbox.*|gnome|gnome-shell|plasma-meta|plasma-desktop|kde-applications.*|cinnamon|mate|deepin.*|zoom|slack-desktop|discord|teams.*|spotify|element-desktop|signal-desktop|telegram-desktop|jellyfin.*|plex.*|kodi|digikam|calibre|zotero|anki|joplin.*|ollama.*)$'
_budget_flagged=0
if [[ -f "$GOODIES" ]]; then
  while IFS= read -r _bg; do
    _bg="${_bg%%#*}"; _bg="${_bg//[[:space:]]/}"
    [[ -n "$_bg" ]] || continue
    [[ -n "${_budget_ok[$_bg]:-}" ]] && continue
    if [[ "$_bg" =~ $_budget_heavy ]]; then
      _v_warn "goodies.list bakes '$_bg' — looks heavy/non-universal; prefer the FETCHED-ONLINE tier (packages/optional + online \`iictl pack\`) per PROPOSAL §4 Pillar 7 / §18 (ISO already ~5.8 GB > 2 GiB cap). If it is genuinely small+universal, add it to validate.sh's _budget_allow to bless it."
      _budget_flagged=$((_budget_flagged+1))
    fi
  done < "$GOODIES"
  if (( _budget_flagged == 0 )); then
    _v_ok "goodies.list within budget (no un-allowlisted heavy/non-universal bakes)"
  fi
else
  _v_warn "no packages/goodies.list — batteries manifest missing"
fi

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
# ledger.sh + mutator.sh are the reversibility substrate — they must NOT appear
# in ii-verify's per-NAME purge (`rm -f .../usr/local/lib/ii/<name>`) either,
# else `iictl revert-all` has no ledger to replay and no mutators to undo with.
grep -vE '^[[:space:]]*#' "$AIROOTFS/usr/local/bin/ii-verify" \
  | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*[[:space:]][^#]*/usr/local/lib/ii/(ledger|mutator)\.sh' \
  && _v_fail "ii-verify purges ledger.sh/mutator.sh by name — they must survive installs" \
  || _v_ok "ii-verify keeps ledger.sh + mutator.sh (reversibility substrate survives)"
grep -Eq '^\s*git\s*$' "$PKGLIST" \
  && _v_ok "git baked (paru + iictl update need it)" \
  || _v_fail "git missing from packages.x86_64"
grep -qE '^\s*- (netinstall|packages)\s*(#.*)?$' "$SETTINGS" \
  && _v_fail "settings.conf still references the removed selection flow" \
  || _v_ok "settings.conf has no selection-screen leftovers"

step "iictl update flags + embedded welcome"
# Bug-class guards for the 'iictl update --noask' fix + the embedded welcome:
#   • iictl must NOT pass the dropped '--noask' to upstream ./setup (it now
#     hard-errors out of getopt), and EVERY flag it does pass must be a real
#     upstream long-option — so an upstream rename can't silently re-break
#     `iictl update`. Cross-checked against the live submodule's getopt decl.
#   • the welcome card runs actions IN-WINDOW (no external terminal spawn).
#   • bare `iictl` opens the card; --auto still runs the switchwall first-boot
#     bootstrap (we suppress upstream's FirstRunExperience that normally does).
#   • ii-post-install records the first_run.txt marker in the ledger with a
#     revert-able kind ('file') so revert-all restores the upstream welcome.
#     (The marker itself is pre-seeded for the installed user via skel-distro →
#     /etc/skel — the content + skel-placement guards live in the next step.)
IICTL_F="$AIROOTFS/usr/local/bin/iictl"
WELCOME_QML_F="$AIROOTFS/usr/share/illogical-impulse/welcome/shell.qml"
SETUP_OPTS_F="$DOTS/sdata/subcmd-install/options.sh"
POST_F="$AIROOTFS/usr/local/bin/ii-post-install"
if [[ -f "$IICTL_F" ]]; then
  _iictl_nc=$(grep -vE '^[[:space:]]*#' "$IICTL_F")   # code only — comments mention --noask/--force
  if grep -qE '\./setup .*--noask' <<<"$_iictl_nc"; then
    _v_fail "iictl passes the removed '--noask' to ./setup — upstream getopt hard-errors on it"
  else
    _v_ok "iictl no longer passes --noask to ./setup"
  fi
  _setup_flags=$(grep -oE '\./setup install[^)]*' <<<"$_iictl_nc" | grep -oE -- '--[a-z][a-z-]+' | sort -u)
  if [[ -f "$SETUP_OPTS_F" ]] \
     && _longopts=$(grep -oE -- '-l [a-z,:-]+' "$SETUP_OPTS_F" | head -1 | sed -E 's/^-l //') \
     && [[ -n "$_longopts" ]]; then
    _bad_flag=0
    for _f in $_setup_flags; do
      case ",$_longopts," in
        *",${_f#--},"*) : ;;
        *) _v_fail "iictl passes '$_f' to ./setup install — not a known upstream long-option"; _bad_flag=1 ;;
      esac
    done
    (( _bad_flag == 0 )) && [[ -n "$_setup_flags" ]] \
      && _v_ok "iictl ./setup install flags ($(echo $_setup_flags)) are all valid upstream long-opts"
  else
    _v_warn "could not parse upstream getopt long-opts ($SETUP_OPTS_F) — flag cross-check skipped"
  fi
  grep -qF '${1:-welcome}' "$IICTL_F" \
    && _v_ok "bare 'iictl' opens the welcome card" \
    || _v_fail "iictl default verb is not 'welcome' — bare iictl should open the card"
  grep -q 'switchwall' "$IICTL_F" \
    && _v_ok "iictl welcome --auto replicates the switchwall first-boot bootstrap" \
    || _v_fail "iictl dropped the switchwall bootstrap — first-boot colours won't generate (upstream's is suppressed)"
else
  _v_fail "iictl missing from airootfs"
fi
if [[ -f "$WELCOME_QML_F" ]]; then
  if grep -qE '"(kitty|foot|alacritty|wezterm|konsole|xterm)"|execDetached' "$WELCOME_QML_F"; then
    _v_fail "welcome shell.qml spawns an external terminal — update/doctor must run in the embedded console"
  else
    _v_ok "welcome shell.qml spawns no external terminal"
  fi
  grep -q 'Process' "$WELCOME_QML_F" && grep -q 'SplitParser' "$WELCOME_QML_F" \
    && _v_ok "welcome shell.qml streams actions into an embedded console (Process + SplitParser)" \
    || _v_fail "welcome shell.qml has no embedded Process/SplitParser console"
fi
if [[ -f "$POST_F" ]]; then
  grep -q 'first_run.txt' "$POST_F" \
    && _v_ok "ii-post-install handles first_run.txt (fail-safe seed + ledger record)" \
    || _v_fail "ii-post-install does not handle first_run.txt — upstream welcome will still fire"
  # The seed must be ledger-recorded with a kind revert-all can actually replay.
  # 'file-seed' is NOT a kind revert-all knows (it fell through to its "unknown
  # kind" branch → the marker was never undone); the canonical revert-able kind
  # is 'file' (revert-all's path inverse rm's the owned path).
  if grep -qE 'ledger_record[[:space:]]+file[[:space:]]+first-run-welcome' "$POST_F"; then
    _v_ok "first_run.txt marker ledger-recorded as kind 'file' (revert-all removes it → upstream welcome returns)"
  elif grep -q 'first-run-welcome' "$POST_F"; then
    _v_fail "first_run.txt marker recorded with a non-'file' kind — revert-all can't replay it (use kind 'file')"
  else
    _v_warn "first_run.txt marker not recorded in the ledger — revert-all couldn't undo it"
  fi
fi

step "first-run welcome suppression (skel marker)"
# Iron-Rule bug-class guard (issue #13): the distro pre-seeds upstream's own
# first_run.txt suppression marker so OUR welcome owns the INSTALLED user's first
# login (no upstream-welcome → distro-welcome double interruption). Three things
# must hold or a first boot regresses:
#   1. The seeded content stays byte-for-byte equal to upstream's firstRunFileContent
#      — if upstream renames/retexts that string, fail HERE at build time, not at
#      the user's first boot (FileView only checks existence, but we keep the exact
#      sanctioned value so we never write foreign content into upstream STATE).
#   2. The marker reaches /etc/skel (installed user, via useradd -m) — together
#      with the skel-distro custom/execs.lua welcome hook, so our card + wallpaper
#      bootstrap replace upstream's first-run.
#   3. The marker must NOT reach /etc/skel-upstream (the liveuser). The liveuser
#      is seeded from skel-upstream + skel-live and has NO distro welcome hook
#      (its custom/execs.lua is the installer launcher), and chroot.sh defers the
#      live wallpaper/colour bootstrap to upstream's FirstRunExperience. Seeding
#      the marker there would suppress upstream's first-run with nothing to
#      replace it — a Try-live boot with no wallpaper, no colours, no welcome.
FRUN_QML="$DOTS/dots/.config/quickshell/ii/services/FirstRunExperience.qml"
FRUN_SEED="$OVERLAY/skel-distro/.local/state/quickshell/user/first_run.txt"
FRUN_REL=".local/state/quickshell/user/first_run.txt"
if [[ ! -f "$FRUN_SEED" ]]; then
  _v_fail "skel-distro first_run.txt seed missing ($FRUN_SEED) — upstream welcome will fire on first login"
elif [[ ! -f "$FRUN_QML" ]]; then
  _v_warn "upstream FirstRunExperience.qml not found — can't cross-check the seeded marker content"
else
  _up_marker=$(sed -nE 's/.*firstRunFileContent:[[:space:]]*"([^"]*)".*/\1/p' "$FRUN_QML")
  _seed_marker=$(cat "$FRUN_SEED")     # command-sub strips the trailing newline
  if [[ -z "$_up_marker" ]]; then
    _v_warn "could not parse firstRunFileContent from FirstRunExperience.qml — marker cross-check skipped"
  elif [[ "$_seed_marker" == "$_up_marker" ]]; then
    _v_ok "skel-distro first_run.txt matches upstream's firstRunFileContent (upstream welcome suppressed)"
  else
    _v_fail "skel-distro first_run.txt drifted from upstream's firstRunFileContent — re-sync the marker (got '$_seed_marker', upstream '$_up_marker')"
  fi
fi
# Installed user MUST get the marker; liveuser MUST NOT.
[[ -f "$AIROOTFS/etc/skel/$FRUN_REL" ]] \
  && _v_ok "first_run.txt staged into /etc/skel (→ installed user; our card owns first login)" \
  || _v_fail "first_run.txt NOT in /etc/skel — installed user would still see upstream's welcome"
if [[ -f "$AIROOTFS/etc/skel-upstream/$FRUN_REL" ]]; then
  _v_fail "first_run.txt LEAKED into /etc/skel-upstream — would suppress the liveuser's upstream first-run (no wallpaper/colours/welcome on a Try-live boot); exclude it from the skel-upstream state copy"
else
  _v_ok "first_run.txt correctly absent from /etc/skel-upstream (liveuser keeps upstream's first-run wallpaper/colour bootstrap)"
fi
# The broad skel-distro/.local/state → skel-upstream copy must still reach the
# liveuser (only first_run.txt is excluded) — kitty-theme.conf is the canary.
_kitty_rel=".local/state/quickshell/user/generated/terminal/kitty-theme.conf"
[[ -f "$AIROOTFS/etc/skel-upstream/$_kitty_rel" ]] \
  && _v_ok "skel-distro OOB state still reaches the liveuser (kitty-theme.conf in /etc/skel-upstream) — exclude is surgical" \
  || _v_warn "kitty-theme.conf missing from /etc/skel-upstream — the first_run.txt exclude may be over-broad"

step "sentinel-fenced custom/*.lua blocks"
# Iron-Rule bug-class guard: every distro write into an upstream custom/*.lua
# slot MUST be wrapped in a `-- >>> illogical-impulse <name>` / `-- <<< …` fence
# so `iictl revert-all` can strip exactly our block (PROPOSAL §4 Pillar 5; the
# shared ii_lua_block_write/ii_lua_block_remove helpers in mutator.sh own all
# reads/writes). A bare distro exec-hook (hl.on / hl.exec_cmd) outside a fence is
# the bug — it would survive a revert. Audits the staged skel (catches profile
# additions too). Upstream's own stubs carry no such hooks, so any hit is ours.
CUSTOM_DIR="$AIROOTFS/etc/skel/.config/hypr/custom"
if [[ -d "$CUSTOM_DIR" ]]; then
  _fence_n=0 _fence_bad=0
  shopt -s nullglob
  for _lua in "$CUSTOM_DIR"/*.lua; do
    _fence_n=$((_fence_n+1))
    if awk '
      /^-- >>> illogical-impulse / { inblk=1; next }
      /^-- <<< illogical-impulse / { inblk=0; next }
      !inblk && /hl\.(on|exec_cmd)\(/ { bad=1 }
      END { exit (bad ? 1 : 0) }
    ' "$_lua"; then
      :   # clean — every distro exec-hook is inside a fence
    else
      _v_fail "unfenced distro block in skel custom/$(basename "$_lua") — wrap in -- >>> illogical-impulse <name> / -- <<< …"
      _fence_bad=$((_fence_bad+1))
    fi
  done
  shopt -u nullglob
  if (( _fence_n == 0 )); then
    _v_warn "no custom/*.lua in skel (expected at least execs.lua with the welcome fence)"
  elif (( _fence_bad == 0 )); then
    _v_ok "$_fence_n custom/*.lua file(s): every distro exec-hook is sentinel-fenced"
  fi
else
  _v_warn "skel custom/ dir missing — run just prepare"
fi

step "iictl.d/ plugin architecture"
# Bug-class guarded here: a silently-broken drop-in (no shebang, not +x, syntax
# error, or no #help: line) loads as a no-op or breaks `iictl help`. Every staged
# plugin must be a runnable, discoverable executable. Mirrors the runtime-script
# syntax step. Also asserts the resolver replaced the old blanket `*) die`.
for _lib in iictl-common.sh ledger.sh mutator.sh; do
  _L="$AIROOTFS/usr/local/lib/ii/$_lib"
  if [[ ! -f "$_L" ]]; then
    _v_fail "iictl lib missing (not staged): $_lib"
  elif bash -n "$_L" 2>/dev/null; then
    _v_ok "$_lib staged + bash -n clean"
  else
    _v_fail "$_lib syntax error"
  fi
done
# The core must resolve unknown verbs via iictl.d/, not hard-die on all of them.
grep -q 'IICTL_D/' "$AIROOTFS/usr/local/bin/iictl" \
  && _v_ok "iictl resolves unknown verbs via iictl.d/ (no blanket die)" \
  || _v_fail "iictl has no iictl.d/ resolver — drop-in subcommands won't load"
_IID="$AIROOTFS/usr/local/lib/ii/iictl.d"
if [[ -d "$_IID" ]]; then
  _plug_n=0 _plug_bad=0
  for _p in "$_IID"/*; do
    [[ -f "$_p" ]] || continue
    _bn=$(basename "$_p")
    _plug_n=$((_plug_n+1))
    [[ -x "$_p" ]] || { _v_fail "iictl.d/$_bn not executable (mkarchiso cp strips mode — chmod at stage)"; _plug_bad=$((_plug_bad+1)); }
    [[ "$(head -c2 "$_p")" == "#!" ]] || { _v_fail "iictl.d/$_bn has no shebang"; _plug_bad=$((_plug_bad+1)); }
    bash -n "$_p" 2>/dev/null || { _v_fail "iictl.d/$_bn syntax error"; _plug_bad=$((_plug_bad+1)); }
    grep -qE '^#help:[[:space:]]' "$_p" || { _v_fail "iictl.d/$_bn missing #help: header (won't show in iictl help)"; _plug_bad=$((_plug_bad+1)); }
  done
  if (( _plug_n == 0 )); then
    _v_warn "no iictl.d/ plugins staged (expected at least the example 'about')"
  elif (( _plug_bad == 0 )); then
    _v_ok "$_plug_n iictl.d/ plugin(s): exec + shebang + bash -n + #help:"
  fi
else
  _v_fail "iictl.d/ plugin dir not staged under usr/local/lib/ii/"
fi

step "revert-all reversibility engine"
# revert-all (#4) replays the ledger in REVERSE to restore vanilla upstream. Its
# bug-class guard (Iron Rule): it MUST strip fenced custom/*.lua blocks through
# the shared mutator inverse (ii_lua_block_remove), never a bespoke rm -rf / sed
# — a hand-rolled stripper would drift from the canonical fence routine, could
# clobber user lines, and might survive a revert. Generic +x/shebang/bash -n/
# #help are already asserted by the "iictl.d/ plugin architecture" step above;
# this adds the engine-specific checks. Comments stripped first so the header's
# *documentation* of the rule can neither satisfy nor trip the code checks.
RA="$AIROOTFS/usr/local/lib/ii/iictl.d/revert-all"
if [[ ! -f "$RA" ]]; then
  _v_fail "iictl.d/revert-all not staged — the reversibility engine is missing"
else
  _ra_code="$(grep -vE '^[[:space:]]*#' "$RA")"
  grep -q 'ii_lua_block_remove' <<<"$_ra_code" \
    && _v_ok "revert-all strips fences via the shared ii_lua_block_remove helper" \
    || _v_fail "revert-all never calls ii_lua_block_remove — it must use the shared mutator fence inverse, not bespoke stripping"
  grep -qE 'source[^#]*/mutator\.sh' <<<"$_ra_code" \
    && _v_ok "revert-all sources mutator.sh (shared inverses + II_FENCE_*)" \
    || _v_fail "revert-all does not source mutator.sh — the shared inverses are unavailable"
  if grep -qE '(sed|awk)[^|]*custom/[^[:space:]]*\.lua' <<<"$_ra_code" \
     || grep -qE 'rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]][^#]*custom/' <<<"$_ra_code"; then
    _v_fail "revert-all open-codes fence stripping against custom/*.lua (sed/awk rewrite or rm -r) — use ii_lua_block_remove"
  else
    _v_ok "revert-all has no bespoke custom/*.lua stripping (no rm -r / sed against a slot)"
  fi
fi

step "iictl pack engine"
# Bug-class guards for the online pack installer (#6). Generic +x/shebang/bash -n/
# #help are already asserted by "iictl.d/ plugin architecture"; these add the
# engine-specific invariants. Comments are stripped first so the header's prose
# can neither satisfy nor trip the code greps.
PK="$AIROOTFS/usr/local/lib/ii/iictl.d/pack"
if [[ ! -f "$PK" ]]; then
  _v_fail "iictl.d/pack not staged — the pack engine is missing"
else
  _pk_code="$(grep -vE '^[[:space:]]*#' "$PK")"
  # (a) every install is recorded → removal is an exact, reversible pacman -Rns.
  grep -q 'ledger_record' <<<"$_pk_code" \
    && _v_ok "pack engine records installs in the ledger (reversible removal)" \
    || _v_fail "pack engine never calls ledger_record — installs would be irreversible"
  # (b) paru is presence-checked / bootstrapped, never assumed (its ISO build is fail-soft).
  grep -q 'command -v paru' <<<"$_pk_code" \
    && _v_ok "pack engine presence-checks paru (bootstrap-or-error, never assumed)" \
    || _v_fail "pack engine does not 'command -v paru' — it must not assume paru is present"
  # (c) #meta:conflicts is enforced BEFORE any pacman transaction.
  grep -q 'ii_conflicts_check' <<<"$_pk_code" \
    && _v_ok "pack engine gates on ii_conflicts_check before pacman" \
    || _v_fail "pack engine never calls ii_conflicts_check — conflicts unenforced"
  # (d) must NOT assume [ii-extra] for post-install installs (it does not survive).
  if grep -q 'ii-extra' <<<"$_pk_code"; then
    _v_fail "pack engine references [ii-extra] — it does not survive install; install from public mirrors + AUR"
  else
    _v_ok "pack engine makes no [ii-extra] assumption (installs from public mirrors + AUR)"
  fi
fi
# (e) no pack NAME is a string-prefix of another. `iictl pack remove X` delegates
# `iictl revert-all pack:X`, whose filter matches a target EXACTLY OR AS A PREFIX
# (the load-bearing `pack:` family selector that reverts every pack). If packs
# 'lang' and 'lang-go' could coexist, `pack remove lang` would also revert
# 'lang-go' and prune its row — silent over-removal. The catalog is closed
# (repo-controlled), so forbid the collision at build time (Iron Rule bug-class).
_PKDIR="$AIROOTFS/usr/share/illogical-impulse/optional"
if [[ -d "$_PKDIR" ]]; then
  _pk_names=()
  shopt -s nullglob
  for _pl in "$_PKDIR"/*.list; do _pk_names+=("$(basename "${_pl%.list}")"); done
  shopt -u nullglob
  _pk_collide=0
  for _a in "${_pk_names[@]}"; do
    for _b in "${_pk_names[@]}"; do
      [[ "$_a" == "$_b" ]] && continue
      [[ "$_b" != "$_a"* ]] || { _v_fail "optional pack name '$_a' is a prefix of '$_b' — 'iictl pack remove $_a' would also revert pack '$_b' (revert-all prefix filter); rename one"; _pk_collide=$((_pk_collide+1)); }
    done
  done
  if (( ${#_pk_names[@]} > 0 && _pk_collide == 0 )); then
    _v_ok "optional pack names are prefix-collision-free (${#_pk_names[@]} pack(s)) — per-pack revert stays exact"
  fi
fi

step "iictl-tui chooser contract (#47)"
# Bug-class guards for the ratatui renderer (iictl-tui) + the iictl chooser
# contract it renders. The engine stays bash; this is the interactive front-end.
# (a) the local PKGBUILD + vendored crate are staged → prebuild builds them into
#     [ii-extra]. (Missing here = the renderer silently never gets built.)
_TUI_PB="$BUILD/aur-pkgbuilds/iictl-tui/PKGBUILD"
_TUI_CRATE="$BUILD/aur-pkgbuilds/iictl-tui/crate"
if [[ -f "$_TUI_PB" && -f "$_TUI_CRATE/Cargo.toml" && -f "$_TUI_CRATE/src/main.rs" ]]; then
  _v_ok "iictl-tui PKGBUILD + vendored crate staged (prebuild → [ii-extra])"
  grep -q "makedepends=('cargo')" "$_TUI_PB" \
    && _v_ok "iictl-tui PKGBUILD declares makedepends=('cargo')" \
    || _v_warn "iictl-tui PKGBUILD: expected makedepends=('cargo') for the Rust build"
else
  _v_fail "iictl-tui PKGBUILD/crate not staged under build/aur-pkgbuilds/iictl-tui/ — the renderer won't build"
fi
# (b) iictl-tui is in the baked package set → pacstrapped, so it SURVIVES install
#     as a real /usr/bin package (no ii-verify exemption, unlike /usr/local/lib/ii).
grep -Eq '^\s*iictl-tui\s*$' "$PKGLIST" \
  && _v_ok "iictl-tui baked into packages.x86_64 (survives install as a package)" \
  || _v_fail "iictl-tui missing from packages.x86_64 — add it to packages/base.list"
# (c) the tweak wrapper is a PURE bridge: it execs iictl-tui and mutates nothing
#     itself (every change must flow through a domain verb → the ledger). Generic
#     +x/shebang/bash -n/#help are already asserted by "iictl.d/ plugin architecture".
_TUI_LIB="$AIROOTFS/usr/local/lib/ii"
_TWK="$_TUI_LIB/iictl.d/tweak"
if [[ ! -f "$_TWK" ]]; then
  _v_fail "iictl.d/tweak not staged — 'iictl tweak' won't resolve"
else
  _twk_code="$(grep -vE '^[[:space:]]*#' "$_TWK")"
  grep -q 'iictl-tui' <<<"$_twk_code" \
    && _v_ok "iictl tweak execs the iictl-tui renderer" \
    || _v_fail "iictl.d/tweak never references iictl-tui — the renderer bridge is broken"
  if grep -qE '\b(pacman|paru|ledger_record|ii_service_|ii_group_|ii_chsh|ii_lua_block_)' <<<"$_twk_code"; then
    _v_fail "iictl.d/tweak mutates state directly — it must only exec iictl-tui (changes flow through domain verbs)"
  else
    _v_ok "iictl tweak mutates nothing itself (pure renderer bridge)"
  fi
fi
# (d) the chooser contract is real + valid. Validate (d1) a canonical sample spec
#     covering all THREE control types and (d2) the live reference emitter
#     `iictl pack --spec` (driven against a throwaway fixture, no network/root)
#     against the same schema. Proves the contract end-to-end on merged code.
#     Uses python3 (already required by prepare's resolve-deps.py).
if command -v python3 >/dev/null 2>&1; then
  read -r -d '' _SPEC_PY <<'PY' || true
import json, sys
spec = json.load(sys.stdin)
assert isinstance(spec.get("domain"), str) and spec["domain"], "missing domain"
ctrls = spec.get("controls")
assert isinstance(ctrls, list) and ctrls, "missing/empty controls"
for c in ctrls:
    t = c.get("type")
    assert t in ("choice", "list", "toggle"), "bad control type: %r" % (t,)
    assert isinstance(c.get("id"), str) and c["id"], "control missing id"
    assert isinstance(c.get("label"), str), "control missing label"
    if t == "choice":
        assert isinstance(c.get("options"), list), "choice needs options[]"
        assert isinstance(c.get("apply"), list), "choice needs apply argv"
    elif t == "list":
        assert isinstance(c.get("apply_add"), list), "list needs apply_add argv"
        assert isinstance(c.get("apply_remove"), list), "list needs apply_remove argv"
    else:
        assert isinstance(c.get("apply_on"), list), "toggle needs apply_on argv"
        assert isinstance(c.get("apply_off"), list), "toggle needs apply_off argv"
PY
  _SAMPLE_SPEC='{"domain":"sample","title":"Sample","controls":[
    {"id":"a","type":"choice","label":"A","current":"x","options":[{"value":"x"},{"value":"y"}],"apply":["sample","set","%v"]},
    {"id":"b","type":"list","label":"B","current":[],"options":[{"value":"p"}],"apply_add":["sample","add","%v"],"apply_remove":["sample","rm","%v"]},
    {"id":"c","type":"toggle","label":"C","current":false,"apply_on":["sample","on"],"apply_off":["sample","off"]}]}'
  if printf '%s' "$_SAMPLE_SPEC" | python3 -c "$_SPEC_PY" 2>/dev/null; then
    _v_ok "chooser spec schema valid for all 3 control types (sample-spec)"
  else
    _v_fail "the sample chooser spec fails the contract schema — the schema/validator drifted"
  fi
  _PK_SPEC="$_TUI_LIB/iictl.d/pack"
  if [[ -x "$_PK_SPEC" ]]; then
    _spec_fix="$(mktemp -d)"
    printf 'steam\n'    > "$_spec_fix/gaming.list"
    printf 'qemu-full\n'> "$_spec_fix/virt.list"
    if _spec_json="$(II_LIB="$_TUI_LIB" II_OPTDIR="$_spec_fix" XDG_STATE_HOME="$_spec_fix/state" \
                     bash "$_PK_SPEC" --spec 2>/dev/null)" \
       && printf '%s' "$_spec_json" | python3 -c "$_SPEC_PY" 2>/dev/null; then
      _v_ok "iictl pack --spec emits a valid chooser spec (reference consumer, end-to-end)"
    else
      _v_fail "iictl pack --spec output fails the chooser-contract schema"
    fi
    rm -rf "$_spec_fix"
  else
    _v_fail "iictl.d/pack not staged/executable — the reference --spec emitter is missing"
  fi
else
  _v_warn "skipped chooser-spec schema check (python3 unavailable)"
fi
# (e) single-picker guard (the anti-clutter ceiling): no domain plugin opens its
#     OWN interactive picker — they all defer to the one iictl-tui renderer.
#     tweak execs iictl-tui (the renderer, allowed); everyone else must not
#     fzf/skim/gum/whiptail/dialog a second chooser into existence.
if [[ -d "$_TUI_LIB/iictl.d" ]]; then
  _pick_bad=0
  for _p in "$_TUI_LIB/iictl.d"/*; do
    [[ -f "$_p" ]] || continue
    [[ "$(basename "$_p")" == "tweak" ]] && continue
    if grep -vE '^[[:space:]]*#' "$_p" | grep -qE '\b(fzf|skim|gum|whiptail|dialog)\b'; then
      _v_fail "iictl.d/$(basename "$_p") opens its own interactive picker — defer to 'iictl tweak' (iictl-tui)"
      _pick_bad=$((_pick_bad+1))
    fi
  done
  (( _pick_bad == 0 )) && _v_ok "no domain plugin opens a second interactive picker (all defer to iictl-tui)"
  # (f) advertise↔answer coupling: every #spec: advertiser must answer --spec, or
  #     the `iictl tweak` listing would offer a domain the renderer can't load.
  _spec_bad=0
  for _p in "$_TUI_LIB/iictl.d"/*; do
    [[ -f "$_p" ]] || continue
    grep -qE '^#spec:[[:space:]]' "$_p" || continue
    grep -q -- '--spec' "$_p" \
      || { _v_fail "iictl.d/$(basename "$_p") advertises #spec: but has no --spec handler — 'iictl tweak' would lie"; _spec_bad=$((_spec_bad+1)); }
  done
  (( _spec_bad == 0 )) && _v_ok "every #spec: advertiser answers --spec (tweak listing is truthful)"
fi

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

step "prebuild [$REPO_NAME] .sig hygiene (BUILD-01)"
# repo-add rejects a detached signature ("not a package file") and, under
# set -e, that aborts the whole build. A signing-enabled host (BUILDENV+=sign
# / a GPGKEY) drops a *.pkg.tar.zst.sig next to every artifact, so every
# *.pkg.tar.* glob in prebuild that feeds repo-add or the nvidia stash MUST
# exclude .sig — mirroring chroot.sh's _nv_pkgs filter. Static grep on the
# source (these scripts run on the host, not in build/).
_PREBUILD="$SCRIPTS/prebuild.sh"
if [[ ! -f "$_PREBUILD" ]]; then
  _v_fail "scripts/prebuild.sh missing"
else
  _pb_sig_ok=1
  # (a) the per-build staging loop (its array feeds 'repo-add … staged_paths[]')
  grep -F -A11 'for b in "${built[@]}"' "$_PREBUILD" | grep -q '== \*\.sig' \
    || { _v_fail "prebuild _build staging loop no longer skips .sig → repo-add chokes on signed-host builds"; _pb_sig_ok=0; }
  # (b) the final re-index must NOT assign an unfiltered glob array (the original bug)
  if grep -qE 'all=\(\s*\*\.pkg\.tar\.\*\s*\)' "$_PREBUILD"; then
    _v_fail "prebuild builds 'all=( *.pkg.tar.* )' unfiltered → final repo-add gets .sig files"; _pb_sig_ok=0
  fi
  # (c) no repo-add is handed a raw glob inline — it must go through a filtered array
  if grep -E 'repo-add[^|]*\*\.pkg\.tar\.\*' "$_PREBUILD" | grep -qvE '^[[:space:]]*#'; then
    _v_fail "prebuild feeds a raw *.pkg.tar.* glob straight to repo-add"; _pb_sig_ok=0
  fi
  # (d) the nvidia-stash staging glob excludes .sig (head -1 could otherwise pick one)
  grep -F 'ls -t "$REPO_PATH/$p-"' "$_PREBUILD" | grep -q 'sig' \
    || { _v_fail "prebuild nvidia-stash glob no longer excludes .sig"; _pb_sig_ok=0; }
  (( _pb_sig_ok )) && _v_ok "prebuild filters detached .sig from every repo-add/stash glob (BUILD-01)"
fi

step "release.yml idempotent re-release (CI-02)"
# The GitHub-release version $VER is the build DATE, so a same-day re-run or a
# workflow_dispatch reuses it — and publish-sf.sh has ALREADY overwritten the
# SourceForge VER/ folder in place by the time the release step runs. An
# UNGUARDED `gh release create "$VER"` then errors on the pre-existing tag and
# reds the run, leaving a published ISO on SourceForge with no matching GitHub
# release (a partial, inconsistent release). Require an idempotency mechanism
# (view-or-edit, delete-then-create, or `--clobber`) so re-runs converge on a
# single consistent release. Static grep on the host-side workflow file.
_REL="$ROOT/.github/workflows/release.yml"
if [[ ! -f "$_REL" ]]; then
  _v_warn "release.yml not found — skipping CI-02 idempotency check"
elif ! grep -q 'gh release create' "$_REL"; then
  _v_warn "release.yml has no 'gh release create' — CI-02 guard not applicable"
elif grep -Eq 'gh release (view|edit|delete)' "$_REL" || grep -q -- '--clobber' "$_REL"; then
  _v_ok "release.yml guards 'gh release create' against same-day tag collisions (CI-02)"
else
  _v_fail "release.yml: 'gh release create' is unconditional — a same-day re-run collides on the date-derived tag, stranding the SourceForge upload (CI-02)"
fi

step "[$REPO_NAME] repo"
[[ -f "$BUILD/pacman.conf" ]] && grep -q "^\[$REPO_NAME\]" "$BUILD/pacman.conf" \
  && _v_ok "pacman.conf has [$REPO_NAME]" || _v_fail "pacman.conf missing [$REPO_NAME]"

step "efiboot loader entries"
ED="$BUILD/efiboot/loader/entries"
[[ -d "$ED" ]] && _v_ok "$(find "$ED" -maxdepth 1 -type f | wc -l) entries" \
               || _v_fail "efiboot/loader/entries/ missing"

step "dev-tooling hygiene"
# `just nspawn` (#31) caches a root-owned, multi-hundred-MB base rootfs under
# .nspawn-cache/ — committing it is the bug-class this guards. Static, repo-level.
if grep -qxF '.nspawn-cache/' "$ROOT/.gitignore" 2>/dev/null; then
  _v_ok ".nspawn-cache/ is git-ignored (just nspawn base stays out of git)"
else
  _v_fail ".nspawn-cache/ not in .gitignore — the just nspawn base rootfs could be committed"
fi

step "release pin-bump ordering (CI-01)"
# The dots-pin bump is split around the build: the submodule WORKING TREE is
# bumped before the build (so the ISO ships the new dots), but the pin is
# committed + pushed to main ONLY after a successful GitHub release. Committing
# the pin up-front strands a fresh-but-unreleased pin on any build/smoke/publish
# failure, which update.sh --check's age gate then reads as "too young → no
# bump" — suppressing releases for ~min_days_between_releases days. Static grep
# on the workflow (release.yml is a tracked file; no build/ needed).
_REL="$ROOT/.github/workflows/release.yml"
if [[ ! -f "$_REL" ]]; then
  _v_fail ".github/workflows/release.yml missing — CI-01 ordering guard can't run"
else
  # First-occurrence line numbers of each ordering marker (|| true so a removed
  # marker yields an empty string the check below reports, rather than tripping
  # set -e). Exclude the gate job's `update.sh --check` from the bump marker.
  _ci_ln() { grep -n -- "$1" "$_REL" | head -1 | cut -d: -f1 || true; }
  _bump_ln="$(grep -Fn './scripts/update.sh' "$_REL" | grep -vF -- '--check' | head -1 | cut -d: -f1 || true)"
  _build_ln="$(_ci_ln 'just docked')"
  _pub_ln="$(_ci_ln 'gh release create')"
  _commit_ln="$(_ci_ln '\[release cron\]')"
  _push_ln="$(grep -n 'git push' "$_REL" | head -1 | cut -d: -f1 || true)"
  if [[ -z "$_bump_ln" || -z "$_build_ln" || -z "$_pub_ln" || -z "$_commit_ln" || -z "$_push_ln" ]]; then
    _v_fail "release.yml missing an ordering marker (update.sh bump / just docked / gh release create / [release cron] / git push) — CI-01 ordering unverifiable"
  else
    _ci_ord_ok=1
    # 1. the working-tree bump must precede the build (the ISO ships new dots).
    if (( _bump_ln >= _build_ln )); then
      _v_fail "release.yml: dots working-tree bump (update.sh) does not precede the build (just docked) — the ISO would ship the OLD dots"; _ci_ord_ok=0
    fi
    # 2. the pin COMMIT must come after the publish (no up-front commit).
    if (( _commit_ln <= _pub_ln )); then
      _v_fail "release.yml: the pin commit ([release cron]) is not after 'gh release create' — a failed build would strand the pin (CI-01)"; _ci_ord_ok=0
    fi
    # 3. the pin PUSH must come after the publish (no up-front push).
    if (( _push_ln <= _pub_ln )); then
      _v_fail "release.yml: 'git push' of the pin is not after 'gh release create' — a failed build would strand the pin (CI-01)"; _ci_ord_ok=0
    fi
    (( _ci_ord_ok )) && _v_ok "release.yml bumps the dots working tree before the build but commits+pushes the pin only after a successful release (CI-01)"
  fi
fi

step "smoke KVM strategy (CI-03)"
# The smoke test boots a multi-GB UEFI ISO into a full Hyprland/Quickshell
# graphical session and probes the framebuffer for >=16 distinct colors — a cold
# boot that effectively never completes within the timeout under TCG software
# emulation. So (a) smoke.sh must FAIL FAST with a clear message when /dev/kvm is
# unavailable rather than silently entering an unwinnable TCG boot, and (b) the
# release workflow must give the runner access to /dev/kvm before the smoke step
# (it is present on ubuntu-latest but not writable by the runner user without the
# enable step). Static greps on the tracked smoke.sh + release.yml.
_SMOKE="$ROOT/scripts/smoke.sh"
if [[ ! -f "$_SMOKE" ]]; then
  _v_fail "scripts/smoke.sh missing — CI-03 fail-fast guard can't run"
elif grep -q 'die "KVM required for the graphical probe' "$_SMOKE" && grep -q '/dev/kvm' "$_SMOKE"; then
  _v_ok "smoke.sh fails fast with a clear message when /dev/kvm is absent instead of hanging under TCG (CI-03)"
else
  _v_fail "smoke.sh does not fail fast on missing /dev/kvm — a KVM-less run silently boots under TCG and hangs to its timeout (CI-03)"
fi
_REL="$ROOT/.github/workflows/release.yml"
if [[ ! -f "$_REL" ]]; then
  _v_warn "release.yml not found — skipping CI-03 KVM-runner check"
elif ! grep -q 'just smoke' "$_REL"; then
  _v_warn "release.yml has no smoke step — CI-03 KVM-runner check not applicable"
elif grep -q '99-kvm4all.rules' "$_REL" || grep -q 'KERNEL=="kvm"' "$_REL"; then
  _v_ok "release.yml grants the runner /dev/kvm access before the smoke test (CI-03)"
else
  _v_fail "release.yml runs the smoke test without enabling /dev/kvm access — the graphical boot probe hangs under TCG on the standard runner (CI-03)"
fi

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

step "additive/reversibility lint"
# Pillar 6 (the four structural checks): skel-upstream precondition + skel-shadow
# collision, packages/optional/*.list validity (no double-bake), and the PII
# guard. '|| true' so an unexpected non-zero can't abort before the summary
# (the FAIL tally, not lint_additive's return code, is what gates the build).
lint_additive || true

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
