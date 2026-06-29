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

# Pillar-6 reversibility lint — the structural checks not already inline below
# (skel-shadow collision, optional-list validity, pack-hook hygiene, PII guard,
# and the skel-upstream precondition). Sourced here, invoked as its own step
# further down; reuses the _v_* tallies above. Checks 2/3/5 of Pillar 6 already
# live inline in their own steps (see tools/lint-additive.sh header for the map).
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
         usr/share/fish/vendor_completions.d/iictl.fish \
         usr/share/bash-completion/completions/iictl \
         usr/share/zsh/site-functions/_iictl \
         usr/share/man/man1/iictl.1.gz \
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
# REV-01: the skel execs.lua ships the welcome hook as a STATIC file that fully
# replaces upstream's empty stub. For `iictl revert-all` to restore vanilla
# byte-for-byte, EVERY distro-authored line must live inside the sentinel fence —
# stripping all `illogical-impulse` fences must leave exactly upstream's stub
# (any leftover comment/code outside the fence would survive revert). Proven
# statically here against the live submodule stub so a stray out-of-fence line
# fails the build, not the install. (Paired with the ledger-record check below
# in the "iictl update flags + embedded welcome" step.)
_skel_execs="$AIROOTFS/etc/skel/.config/hypr/custom/execs.lua"
_up_execs="$DOTS/dots/.config/hypr/custom/execs.lua"
if [[ -f "$_skel_execs" && -f "$_up_execs" ]]; then
  if cmp -s <(awk '/^-- >>> illogical-impulse /{f=1;next} /^-- <<< illogical-impulse /{f=0;next} !f' "$_skel_execs") "$_up_execs"; then
    _v_ok "stripping the welcome fence from skel execs.lua yields upstream's stub byte-for-byte (revert-all restores vanilla)"
  else
    _v_fail "skel execs.lua has distro content OUTSIDE the welcome fence — revert-all would not restore upstream's stub; move it inside the -- >>> illogical-impulse welcome fence"
  fi
elif [[ ! -f "$_up_execs" ]]; then
  _v_warn "upstream execs.lua stub not found ($_up_execs) — fence byte-identity check skipped (run git submodule update)"
fi
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
  # REV-01: the distro welcome exec-hook is a sentinel-fenced `welcome` block in
  # the upstream custom/execs.lua slot, shipped STATICALLY via skel-distro →
  # /etc/skel. Arriving as a static skel file it never passes through
  # ii_lua_block_write, so ii-post-install must record the matching 'lua-block'
  # ledger row itself — otherwise `iictl revert-all` can't strip the fence and
  # custom/execs.lua never returns to upstream's empty stub (the distro hook
  # survives a "vanilla" revert). The row must reference the execs.lua path with
  # the 'welcome' block name as restore_hint (what ii_lua_block_remove consumes).
  if grep -Eq 'ledger_record[[:space:]]+lua-block[^#]*custom/execs\.lua[^#]*welcome' "$POST_F"; then
    _v_ok "welcome execs.lua fence ledger-recorded as kind 'lua-block' (revert-all strips it → upstream stub returns)"
  else
    _v_fail "welcome execs.lua fence not recorded as a 'lua-block' row in ii-post-install — iictl revert-all can't strip it (static skel fence is unrevertable)"
  fi
  # REV-02: install-time group memberships must go through the idempotent,
  # ledger-recording ii_group_add mutator (tagged src=install) — NOT a raw
  # `usermod -aG` (unledgered → `revert-all --deep` can't peel them; wheel is
  # load-bearing for the nopasswd sudo drop-in) and NOT a raw `ledger_record
  # group` (bypasses the mutator's idempotency + only-record-what-we-add
  # contract). Comments stripped so the code-only lines are what we judge. The
  # raw `usermod -aG video,input,...` survives ONLY as the dev-checkout fallback
  # (gated behind a `type ii_group_add` else-branch); the install path must use
  # ii_group_add. We assert: (a) ii_group_add is invoked, (b) it's tagged
  # II_GROUP_SRC=install, and (c) no `ledger_record group` raw row remains.
  _post_nc=$(grep -vE '^[[:space:]]*#' "$POST_F")
  if grep -q 'ii_group_add' <<<"$_post_nc"; then
    _v_ok "ii-post-install adds groups via ii_group_add (idempotent, ledgered, revertible)"
  else
    _v_fail "ii-post-install does not use ii_group_add for group memberships — raw usermod -aG is unledgered (revert-all --deep can't peel it)"
  fi
  if grep -q 'II_GROUP_SRC=install' <<<"$_post_nc"; then
    _v_ok "ii-post-install tags install-time group rows src=install (II_GROUP_SRC=install → revert-all --deep gates them)"
  else
    _v_fail "ii-post-install group adds are not tagged II_GROUP_SRC=install — revert-all --deep can't distinguish them from iictl-time rows"
  fi
  if grep -Eq 'ledger_record[[:space:]]+group\b' <<<"$_post_nc"; then
    _v_fail "ii-post-install records a group via raw ledger_record — route it through ii_group_add (idempotent + only-records-what-it-adds) instead"
  else
    _v_ok "ii-post-install records no raw 'ledger_record group' rows (group adds go through ii_group_add)"
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

step "iictl completions + grouped help + man pages (#12)"
# Shell completions are distro-owned SYSTEM files under /usr/share/{fish,
# bash-completion,zsh} (not user dotfiles) + baked man pages under
# /usr/share/man/man1. They must (a) exist, (b) the bash one must bash -n
# clean, and (c) each must do DYNAMIC iictl.d/ discovery — a frozen verb list
# would silently drift from the actual plugin set (Iron-Rule guard).
_FISH_C="$AIROOTFS/usr/share/fish/vendor_completions.d/iictl.fish"
_BASH_C="$AIROOTFS/usr/share/bash-completion/completions/iictl"
_ZSH_C="$AIROOTFS/usr/share/zsh/site-functions/_iictl"
for _cf in "$_FISH_C" "$_BASH_C" "$_ZSH_C"; do
  [[ -s "$_cf" ]] && _v_ok "completion present: ${_cf#"$AIROOTFS"/}" \
                  || _v_fail "completion missing/empty: ${_cf#"$AIROOTFS"/}"
done
# The bash completion is the one that runs under bash → bash -n it (mirrors the
# runtime-scripts syntax loop).
if [[ -f "$_BASH_C" ]]; then
  bash -n "$_BASH_C" 2>/dev/null && _v_ok "bash completion bash -n clean" \
                                 || _v_fail "bash completion has a syntax error"
fi
# Dynamic-discovery guard: every completion must reference the iictl.d/ dir, so
# new plugins tab-complete with no completion-file edit (not a frozen list).
_disc_bad=0
for _cf in "$_FISH_C" "$_BASH_C" "$_ZSH_C"; do
  [[ -f "$_cf" ]] || continue
  grep -q '/usr/local/lib/ii/iictl.d' "$_cf" \
    || { _v_fail "${_cf#"$AIROOTFS"/} does not discover /usr/local/lib/ii/iictl.d — frozen verb list will drift"; _disc_bad=1; }
done
(( _disc_bad == 0 )) && _v_ok "all completions discover iictl.d/ dynamically (no frozen verb list)"
# bash completion registers via complete -F; zsh declares #compdef.
grep -q 'complete -F _iictl iictl' "$_BASH_C" 2>/dev/null \
  && _v_ok "bash completion registers _iictl for iictl" \
  || _v_fail "bash completion never registers (complete -F _iictl iictl) — tab does nothing"
[[ "$(head -1 "$_ZSH_C" 2>/dev/null)" == '#compdef iictl' ]] \
  && _v_ok "zsh completion has #compdef iictl header" \
  || _v_fail "zsh _iictl missing the #compdef iictl header — zsh won't load it"
# Grouped help + --version aliases in the core.
grep -q 'Core commands:' "$AIROOTFS/usr/local/bin/iictl" \
  && grep -q 'Feature commands (plugins):' "$AIROOTFS/usr/local/bin/iictl" \
  && _v_ok "iictl help prints grouped sections (Core / Feature plugins)" \
  || _v_fail "iictl help dropped the grouped section headers"
grep -qE 'version\|--version\|-V' "$AIROOTFS/usr/local/bin/iictl" \
  && _v_ok "iictl --version / -V alias version" \
  || _v_fail "iictl missing --version / -V aliases"
# Baked man pages: top-level + non-empty roff under each gz.
_MAN1="$AIROOTFS/usr/share/man/man1"
if [[ -f "$_MAN1/iictl.1.gz" ]]; then
  if command -v gzip >/dev/null 2>&1 && gzip -dc "$_MAN1/iictl.1.gz" 2>/dev/null | grep -q '\.TH IICTL 1'; then
    _v_ok "iictl.1.gz baked + non-empty roff (.TH IICTL)"
  else
    _v_fail "iictl.1.gz empty or not roff (.TH IICTL header missing)"
  fi
else
  _v_fail "iictl.1.gz man page not baked under usr/share/man/man1/"
fi
# One iictl-<verb>.1.gz per plugin, each non-empty.
_man_plug=0 _man_bad=0
if [[ -d "$_IID" ]]; then
  for _p in "$_IID"/*; do
    [[ -f "$_p" && -x "$_p" ]] || continue
    _v="$(basename "$_p")"
    _mg="$_MAN1/iictl-$_v.1.gz"
    _man_plug=$((_man_plug+1))
    if [[ -f "$_mg" ]] && gzip -dc "$_mg" 2>/dev/null | grep -q '\.TH'; then :; else
      _v_fail "missing/empty man page for plugin '$_v' ($_mg)"; _man_bad=1
    fi
  done
fi
(( _man_bad == 0 )) && _v_ok "$_man_plug per-plugin man page(s) baked + non-empty"
step "nvim chooser plugin (NVIM-01)"
# NVIM-01 (#17): the Neovim-distro chooser is a survive-path iictl.d/ drop-in that
# clones a chosen distro ONLINE at a pinned rev and owns the unowned nvim seam
# (~/.config/nvim + ~/.local/{share,state}/nvim) reversibly. Three bug-class
# guards beyond the generic plugin hygiene (exec/shebang/bash -n/#help already
# asserted above): (a) the plugin is actually staged (a named guard so it can
# never silently vanish from the image); (b) NOTHING nvim is baked into skel —
# the baked default MUST stay vanilla (empty ~/.config/nvim); (c) the plugin
# owns DIRECTORY trees, so revert-all's path|file inverse MUST rm -rf (plain rm -f
# errors on a dir → the tree would survive a revert and the Iron Law would break).
NVP="$AIROOTFS/usr/local/lib/ii/iictl.d/nvim"
if [[ ! -f "$NVP" ]]; then
  _v_fail "iictl.d/nvim not staged — the Neovim-distro chooser is missing"
else
  # (a) named existence + exec/shebang/bash -n/#help (mirrors the generic loop so
  #     a regression in THIS plugin is attributed to NVIM-01, not a generic fail).
  _nv_bad=0
  [[ -x "$NVP" ]] || { _v_fail "iictl.d/nvim not executable (mkarchiso cp strips mode — chmod at stage)"; _nv_bad=$((_nv_bad+1)); }
  [[ "$(head -c2 "$NVP")" == "#!" ]] || { _v_fail "iictl.d/nvim has no shebang"; _nv_bad=$((_nv_bad+1)); }
  bash -n "$NVP" 2>/dev/null || { _v_fail "iictl.d/nvim syntax error"; _nv_bad=$((_nv_bad+1)); }
  grep -qE '^#help:[[:space:]]' "$NVP" || { _v_fail "iictl.d/nvim missing #help: header (won't show in iictl help)"; _nv_bad=$((_nv_bad+1)); }
  _nv_code="$(grep -vE '^[[:space:]]*#' "$NVP")"
  # The chooser must clone the distro at a PINNED rev (never track HEAD) and
  # never edit an upstream-owned path. A git fetch of a pinned ref is the tell.
  grep -qE 'git[[:space:]]+fetch' <<<"$_nv_code" \
    || { _v_fail "iictl.d/nvim never git-fetches — it must clone the chosen distro online (NVIM-01)"; _nv_bad=$((_nv_bad+1)); }
  grep -qE 'ledger_record' <<<"$_nv_code" \
    || { _v_fail "iictl.d/nvim never calls ledger_record — a 'set' would be unrevertable (NVIM-01)"; _nv_bad=$((_nv_bad+1)); }
  (( _nv_bad == 0 )) && _v_ok "iictl.d/nvim staged: exec + shebang + bash -n + #help, pinned online clone, ledger-recorded (NVIM-01)"
fi

# (b) baked default stays vanilla: NO nvim config may ship in either skel tree.
#     Upstream ships zero ~/.config/nvim (the unowned seam); the chooser must
#     leave it empty by default so a fresh user's `nvim` opens bare. A stray
#     skel-distro/.config/nvim (or share/state) would bake an opinionated editor
#     into every install — the exact thing #17 refuses (and a skel-shadow risk).
_nv_skel_bad=0
for _sk in "$AIROOTFS/etc/skel" "$AIROOTFS/etc/skel-upstream" "$OVERLAY/skel-distro" "$OVERLAY/skel-live"; do
  [[ -d "$_sk" ]] || continue
  for _np in .config/nvim .local/share/nvim .local/state/nvim; do
    if [[ -e "$_sk/$_np" ]]; then
      _v_fail "NVIM-01: $_sk/$_np exists — no nvim config may be baked into skel (the baked default must be vanilla/empty)"
      _nv_skel_bad=$((_nv_skel_bad+1))
    fi
  done
done
(( _nv_skel_bad == 0 )) && _v_ok "NVIM-01: no nvim config baked into any skel tree (baked default is vanilla; no skel-shadow)"

# Focused offline self-test: the chooser's no-network mechanics (refusal gate,
# backup, stamp, ledger record, restore round-trip, theme). It runs the REAL
# plugin against a throwaway $HOME with II_LIB relocated — no root, no network,
# no /usr/local install — so it is safe to run inline here (unlike the nspawn
# round-trip). A regression in the reversible-state machine reds the build.
_NV_TEST="$ROOT/tests/nvim-chooser.sh"
if [[ ! -f "$_NV_TEST" ]]; then
  _v_fail "NVIM-01: tests/nvim-chooser.sh missing — the chooser self-test is gone"
elif ! bash -n "$_NV_TEST" 2>/dev/null; then
  _v_fail "NVIM-01: tests/nvim-chooser.sh has a syntax error"
elif bash "$_NV_TEST" >/dev/null 2>&1; then
  _v_ok "NVIM-01: tests/nvim-chooser.sh self-test passes (refusal gate, backup, stamp, ledger, restore, theme)"
else
  _v_fail "NVIM-01: tests/nvim-chooser.sh self-test FAILED — run it directly to see which assertion broke"
fi

# (c) revert-all owns directory trees → must rm -rf, not rm -f, in the path|file
#     inverse. Comments stripped so the historic-bug note above the line can't
#     satisfy/trip this grep.
_RA_NV="$AIROOTFS/usr/local/lib/ii/iictl.d/revert-all"
if [[ -f "$_RA_NV" ]]; then
  _ra_nv_code="$(grep -vE '^[[:space:]]*#' "$_RA_NV")"
  if grep -qE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+"\$p"' <<<"$_ra_nv_code" \
     || grep -qE 'rm[[:space:]]+-rf[[:space:]]+"\$p"' <<<"$_ra_nv_code"; then
    _v_ok "NVIM-01: revert-all's path|file inverse rm -rf's owned paths (removes a dir-owning domain's tree, e.g. nvim)"
  else
    _v_fail "NVIM-01: revert-all's path|file inverse still uses rm -f \"\$p\" — a directory owned_path (e.g. ~/.config/nvim) survives a revert (Iron Law break)"
  fi
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

step "iictl theme flavor engine + §9 reversibility seam (THEME-01)"
# THEME-01: the theming domain (#16) drives upstream's Material You pipeline
# rather than forking it, and bakes static themed defaults only into UNOWNED
# paths. Four bug-class guards, each a real reversibility/Iron-Law trap:
#   (a) NO overlay/skel-distro file may land in an upstream rsync --delete dir —
#       it would be silently WIPED on the next `iictl update`, so it is never a
#       reliable default and (worse) masks the real upstream file until then.
#   (b) NO distro file may ship/edit matugen's config.toml or add a distro
#       `[templates.*]` block: ~/.config/matugen is rsync --delete'd, so any
#       template we add there vanishes on update — the colour pipeline must be
#       driven via switchwall.sh's public flags, not by patching matugen config.
#   (c) every baked flavor seed (themes/*.conf) must parse and declare a valid
#       #RRGGBB seed — a seedless flavor would `die` at `set` time on a user.
#   (d) the theme plugin must DRIVE switchwall.sh (no forked colour logic) and
#       the revert engine must know the theme-accent inverse (--color clear), or
#       `iictl revert-all` could not restore the empty, never-set accent.
_SKD="$OVERLAY/skel-distro"
# (a) sync-deleted dirs (mirrors 30-skel.sh's `rsync -a --delete` set + the
# broader read-only seam from the Iron Law). A skel-distro file under any of
# these is wiped on update — refuse it.
_th_sync_deleted=(
  ".config/quickshell" ".config/matugen" ".config/fontconfig"
  ".config/hypr/hyprland" ".config/hypr/hyprlock" ".config/zshrc.d"
)
if [[ -d "$_SKD" ]]; then
  _th_leak=0
  for _sd in "${_th_sync_deleted[@]}"; do
    if [[ -e "$_SKD/$_sd" ]]; then
      _v_fail "skel-distro ships files under '$_sd' — an upstream rsync --delete path; they are WIPED on 'iictl update' (THEME-01a)"
      _th_leak=$((_th_leak+1))
    fi
  done
  # fish is --delete EXCEPT conf.d (the sanctioned ii-*.fish seam) — flag any
  # skel-distro fish file that is NOT under conf.d.
  if [[ -d "$_SKD/.config/fish" ]]; then
    while IFS= read -r _ff; do
      [[ "$_ff" == *"/.config/fish/conf.d/"* ]] && continue
      _v_fail "skel-distro fish file outside conf.d ('${_ff#"$_SKD"/}') — fish/ is rsync --delete'd except conf.d (THEME-01a)"
      _th_leak=$((_th_leak+1))
    done < <(find "$_SKD/.config/fish" -type f 2>/dev/null)
  fi
  (( _th_leak == 0 )) && _v_ok "no skel-distro file lands in an upstream rsync --delete dir (THEME-01a)"
else
  _v_warn "overlay/skel-distro missing — THEME-01a skipped"
fi
# (b) we must NOT ship/edit matugen config or add a distro [templates.*] block
# (anywhere in overlay/ — airootfs or skel). Upstream owns matugen entirely.
_th_matugen=0
while IFS= read -r _mf; do
  _v_fail "distro ships/edits a matugen config.toml ('${_mf#"$OVERLAY"/}') — ~/.config/matugen is rsync --delete'd; drive colours via switchwall.sh, never matugen config (THEME-01b)"
  _th_matugen=$((_th_matugen+1))
done < <(find "$OVERLAY" -type f -path '*/matugen/config.toml' 2>/dev/null)
if grep -rqsF '[templates.' "$OVERLAY" 2>/dev/null; then
  _v_fail "a distro file introduces a '[templates.' matugen block under overlay/ — forbidden (matugen is rsync --delete'd) (THEME-01b)"
  _th_matugen=$((_th_matugen+1))
fi
(( _th_matugen == 0 )) && _v_ok "no distro matugen config / [templates.*] block (colours driven via switchwall.sh only) (THEME-01b)"
# (c) every baked flavor seed parses + declares a valid #RRGGBB seed.
_THEMES="$AIROOTFS/usr/share/illogical-impulse/themes"
if [[ -d "$_THEMES" ]]; then
  shopt -s nullglob; _th_confs=("$_THEMES"/*.conf); shopt -u nullglob
  if (( ${#_th_confs[@]} == 0 )); then
    _v_fail "no flavor seeds staged at usr/share/illogical-impulse/themes/ — 'iictl theme list' would be empty (THEME-01c)"
  else
    _th_seed_bad=0
    for _tc in "${_th_confs[@]}"; do
      _ts="$(grep -E '^[[:space:]]*seed[[:space:]]*=' "$_tc" | tail -n1 | cut -d= -f2- | tr -d '[:space:]')"
      if [[ "$_ts" =~ ^#?[A-Fa-f0-9]{6}$ ]]; then
        :
      else
        _v_fail "flavor seed $(basename "$_tc") has no valid #RRGGBB seed= (got '${_ts:-<none>}') (THEME-01c)"
        _th_seed_bad=$((_th_seed_bad+1))
      fi
    done
    (( _th_seed_bad == 0 )) && _v_ok "${#_th_confs[@]} flavor seed(s): each declares a valid #RRGGBB seed (THEME-01c)"
  fi
else
  _v_fail "themes dir not staged (usr/share/illogical-impulse/themes/) — the flavor catalog is missing (THEME-01c)"
fi
# (d) the theme plugin DRIVES switchwall.sh (no forked colour logic) + carries a
# #spec: header; the revert engine knows the theme-accent inverse. Generic
# exec/shebang/bash -n/#help: are covered by the "iictl.d/ plugin architecture"
# step; this adds the domain-specific ones. Comments stripped first so the
# header prose can neither satisfy nor trip the code greps.
_THP="$AIROOTFS/usr/local/lib/ii/iictl.d/theme"
if [[ ! -f "$_THP" ]]; then
  _v_fail "iictl.d/theme not staged — the flavor engine is missing (THEME-01d)"
else
  _thp_code="$(grep -vE '^[[:space:]]*#' "$_THP")"
  grep -qE 'switchwall\.sh' <<<"$_thp_code" \
    && _v_ok "theme plugin drives upstream switchwall.sh (no forked colour logic) (THEME-01d)" \
    || _v_fail "theme plugin never references switchwall.sh — it must DRIVE upstream's pipeline, not duplicate colour logic (THEME-01d)"
  grep -qE '^#spec:[[:space:]]' "$_THP" \
    && _v_ok "theme plugin advertises a #spec: header (drives 'iictl tweak theme')" \
    || _v_fail "theme plugin missing #spec: header — 'iictl tweak' won't list it (THEME-01d)"
  # The plugin must NOT write an upstream-owned colour path itself (it only RUNS
  # switchwall.sh + READS config.json). A direct write to matugen/quickshell-ii/
  # the generated STATE dir would be an Iron-Law breach.
  if grep -qE '>[[:space:]]*"?[^"]*(\.config/matugen|\.config/quickshell/ii|generated/(colors\.json|material_colors))' <<<"$_thp_code"; then
    _v_fail "theme plugin appears to WRITE an upstream-owned colour path (matugen/quickshell-ii/generated) — only switchwall.sh may (THEME-01d)"
  else
    _v_ok "theme plugin writes no upstream-owned colour path (only runs switchwall.sh) (THEME-01d)"
  fi
fi
# the revert engine must know how to undo a theme accent (clear it).
if [[ -f "$RA" ]]; then
  _ra_theme="$(grep -vE '^[[:space:]]*#' "$RA")"
  grep -qE 'theme-accent' <<<"$_ra_theme" && grep -qE -- '--color clear' <<<"$_ra_theme" \
    && _v_ok "revert-all knows the theme-accent inverse (switchwall.sh --color clear → never-set) (THEME-01d)" \
    || _v_fail "revert-all has no theme-accent inverse — 'iictl revert-all' can't clear a set flavor accent (THEME-01d)"
fi
# the opt-in recolour watcher is the SINGLE owner of the hook, off by default:
# its autostart fence must NOT be baked into the skel custom/execs.lua (only
# written at runtime by `iictl theme watch enable`).
_SKEL_EXECS="$AIROOTFS/etc/skel/.config/hypr/custom/execs.lua"
if [[ -f "$_SKEL_EXECS" ]] && grep -qF 'theme-recolor' "$_SKEL_EXECS"; then
  _v_fail "the recolour-watcher fence ('theme-recolor') is baked into skel execs.lua — it must be OFF by default (opt-in via 'iictl theme watch enable') (THEME-01d)"
else
  _v_ok "recolour watcher is off by default (no theme-recolor fence baked into skel execs.lua) (THEME-01d)"
fi

step "reversibility round-trip e2e test (TEST-02)"
# The static checks above assert the reversibility STRUCTURE; the e2e test
# (tests/revert-roundtrip.sh + its in-container payload) DEMONSTRATES it — seed
# the ledger via the real mutators + pack engine in a throwaway `just nspawn`
# box, run `iictl revert-all`, assert vanilla returns byte-for-byte. This static
# guard keeps the demonstration itself from silently rotting: both halves must
# exist, parse, and be wired into a `just` recipe + CI (it needs root + nspawn,
# so it is NOT run here — `just test-revert` / the test-revert.yml job run it).
_E2E_DRV="$ROOT/tests/revert-roundtrip.sh"
_E2E_PAY="$ROOT/tests/revert-roundtrip.in.sh"
for _e2e in "$_E2E_DRV" "$_E2E_PAY"; do
  if [[ ! -f "$_e2e" ]]; then
    _v_fail "reversibility e2e test missing: ${_e2e#"$ROOT"/}"
  elif bash -n "$_e2e" 2>/dev/null; then
    _v_ok "${_e2e#"$ROOT"/} present + bash -n clean"
  else
    _v_fail "${_e2e#"$ROOT"/} has a syntax error"
  fi
done
# The payload must actually drive the four ledger-kind seams the ticket names
# (so the demonstration can never quietly shrink to a weaker subset).
if [[ -f "$_E2E_PAY" ]]; then
  _e2e_miss=0
  for _need in ii_service_enable ii_group_add ii_lua_block_write 'iictl pack install' 'revert-all'; do
    grep -qF -- "$_need" "$_E2E_PAY" || { _v_fail "e2e payload never exercises '$_need'"; _e2e_miss=$((_e2e_miss+1)); }
  done
  (( _e2e_miss == 0 )) \
    && _v_ok "e2e payload seeds all four ledger kinds (service/group/lua-block/pack) + runs revert-all"
fi
# Wired into the just surface (so the maintainer + CI can invoke it).
grep -qE '^test-revert:' "$ROOT/justfile" \
  && _v_ok "'just test-revert' recipe wires the round-trip into the just surface" \
  || _v_fail "no 'test-revert' recipe in justfile — the round-trip is not invocable via just"
# Wired into CI (a dedicated workflow runs it per-PR on a privileged runner).
if [[ -f "$ROOT/.github/workflows/test-revert.yml" ]] \
   && grep -q 'test-revert' "$ROOT/.github/workflows/test-revert.yml"; then
  _v_ok "test-revert.yml CI workflow runs the round-trip per-PR"
else
  _v_fail ".github/workflows/test-revert.yml missing or does not invoke the round-trip"
fi

step "ledger durability — flock + comma-safe owned_paths (REV-05)"
# REV-05: ledger durability bug-class guard. Three real failure modes:
#   (a) ledger_record's append and revert-all's snapshot→replay→rewrite race. A
#       row appended (e.g. a parallel `iictl pack install`) between revert-all's
#       mapfile snapshot and its rewrite would be silently dropped → permanently
#       unrevertable. BOTH sides must serialize on a flock (the sidecar lock).
#   (b) owned_paths is comma-JOINED but a path may CONTAIN a comma. Without
#       escaping, such a path splits into bogus fragments at revert → wrong files
#       removed / the real one survives. Paths must be comma-escaped at write and
#       decoded at read (ledger_escape_path / ledger_unescape_path).
# Comments are stripped first so this section's own prose can't satisfy a grep.
LG="$AIROOTFS/usr/local/lib/ii/ledger.sh"
if [[ ! -f "$LG" ]]; then
  _v_fail "ledger.sh not staged — the reversibility manifest is missing"
elif [[ ! -f "$RA" ]]; then
  : # revert-all absence already failed above
else
  _lg_code="$(grep -vE '^[[:space:]]*#' "$LG")"
  # (a) flock serialization — ledger_record (writer) AND revert-all (rewriter).
  grep -q 'flock' <<<"$_lg_code" \
    && _v_ok "ledger_record serializes its append under flock (no lost concurrent record)" \
    || _v_fail "ledger.sh never calls flock — a concurrent ledger_record races revert-all's rewrite and is silently lost (REV-05)"
  grep -q 'flock' <<<"$_ra_code" \
    && _v_ok "revert-all takes a flock around its read-replay-rewrite (no row lost mid-revert)" \
    || _v_fail "revert-all never calls flock — a row appended between its snapshot and rewrite is silently dropped (REV-05)"
  # (b) comma-escape helpers defined in ledger.sh AND consumed on the revert path.
  if grep -qE '^[[:space:]]*ledger_escape_path[[:space:]]*\(\)' <<<"$_lg_code" \
     && grep -qE '^[[:space:]]*ledger_unescape_path[[:space:]]*\(\)' <<<"$_lg_code"; then
    _v_ok "ledger.sh defines ledger_escape_path/ledger_unescape_path (owned_paths comma-safe)"
  else
    _v_fail "ledger.sh lacks ledger_escape_path/ledger_unescape_path — a path containing a comma corrupts the owned_paths column (REV-05)"
  fi
  grep -q 'ledger_unescape_path' <<<"$_ra_code" \
    && _v_ok "revert-all decodes owned_paths via ledger_unescape_path before splitting (comma-in-path round-trips)" \
    || _v_fail "revert-all splits owned_paths on comma without ledger_unescape_path — a comma-bearing path reverts wrongly (REV-05)"
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
  # (e) ATOMIC RECORDING (REV-03 / #67). The success path MUST record the
  # kind=pack row BEFORE running the post-add hook — otherwise a post-add that
  # exit/die's would leave the just-installed members with no ledger row
  # (`pack remove` → "not installed", `revert-all` can't undo them). Assert the
  # FIRST line that records a pack row (a ledger_record pack OR the factored
  # _record_pack helper) precedes the FIRST _run_hook ... post-add invocation in
  # cmd_install. Line-number ordering over the comment-stripped code.
  _pk_rec_ln="$(grep -nE '(ledger_record[[:space:]]+pack|_record_pack)' "$PK" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1)"
  _pk_hook_ln="$(grep -nE '_run_hook[^#]*post-add' "$PK" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1)"
  if [[ -n "$_pk_rec_ln" && -n "$_pk_hook_ln" && "$_pk_rec_ln" -lt "$_pk_hook_ln" ]]; then
    _v_ok "pack engine records the kind=pack row BEFORE the post-add hook (atomic on hook failure, REV-03)"
  else
    _v_fail "pack engine runs the post-add hook before recording the pack row — a die()-ing hook would orphan the install (REV-03/#67)"
  fi
  # (f) The AUR-phase failure path must record what landed instead of die()-ing
  # with the misleading 'nothing recorded' line: after an official `pacman -S`
  # commits, a later paru failure that aborts BEFORE recording orphans the
  # official members. Forbid the old misleading message and require a record
  # call on the failure side (the paru branch must reach a pack-record).
  if grep -qE 'nothing recorded \(no half state\)' "$PK"; then
    _v_fail "pack engine still emits 'nothing recorded (no half state)' on a partial-commit failure — official members can be orphaned (REV-03/#67)"
  else
    _v_ok "pack engine no longer claims 'no half state' on partial failure (records what landed, REV-03)"
  fi
  # (g) post-add hooks are subshell-fenced so a stray exit/die can't abort the
  # engine before/after the row is recorded. Require the hook source to run in a
  # ( … ) subshell.
  grep -qE '\([[:space:]]*source[[:space:]]+"\$hook"[[:space:]]*\)' "$PK" \
    && _v_ok "pack engine subshell-fences sourced hooks (a hook exit/die can't abort the engine, REV-03)" \
    || _v_fail "pack engine sources hooks unfenced — a hook that exit/die's aborts the engine before recording (REV-03/#67)"
fi
# (e) no pack NAME is a string-prefix of another. `iictl pack remove X` delegates
# `iictl revert-all pack:X`, whose filter matches a target EXACTLY OR AS A PREFIX
# (the load-bearing `pack:` family selector that reverts every pack). If packs
# 'lang' and 'lang-go' could coexist, `pack remove lang` would also revert
# 'lang-go' and prune its row — silent over-removal. The catalog is closed
# (repo-controlled), so forbid the collision at build time (Iron Rule bug-class).
_PKDIR="$AIROOTFS/usr/share/illogical-impulse/optional"
# IMMUNE-03: FAIL (not silently skip) when the staged catalog is missing while a
# source catalog exists — a silent skip would false-pass a build whose
# 45-optional-packs.sh staging broke, shipping an unaudited (possibly colliding)
# pack catalog. Only an empty SOURCE catalog (no packs authored at all) is a
# legitimate no-op.
if [[ ! -d "$_PKDIR" ]]; then
  if [[ -d "$PACKAGES/optional" ]] && compgen -G "$PACKAGES/optional/*.list" >/dev/null; then
    _v_fail "optional pack catalog not staged ($_PKDIR) though packages/optional/ has lists — prefix-collision check SKIPPED (would false-pass); run 'just prepare' (45-optional-packs.sh)"
  else
    _v_ok "optional pack catalog: none authored (packages/optional/ empty) — prefix-collision check is a no-op"
  fi
else
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

step "pack removal robustness — shared deps + side-effect sweep (REV-04)"
# REV-04: two real failure modes in `iictl pack remove`.
#   (a) The recorded set is members + the deps they pulled. The old revert-all
#       ran one `pacman -Rns --noconfirm $set >/dev/null 2>&1`: if any recorded
#       dep is STILL required by another installed pack, pacman aborts the WHOLE
#       (atomic) transaction and the user saw only a generic "failed" (stderr
#       swallowed). The pkg/pack inverse must filter to the SAFELY-removable
#       subset (skip a dep an outsider still needs) and SURFACE pacman's stderr
#       on failure.
#   (b) A pack's post-add hook records side-effect rows (service/group/chsh/
#       lua-block) keyed on the affected OBJECT, not on `pack:<name>`, so
#       `iictl revert-all pack:<name>` never matched them → they LINGERED in the
#       ledger forever. The pack engine stamps the pack tag into those rows and
#       revert-all's filter sweeps them with the pack.
# Comments are stripped first so this section's prose can't satisfy a grep.
MUT="$AIROOTFS/usr/local/lib/ii/mutator.sh"
if [[ ! -f "$RA" ]]; then
  : # revert-all absence already failed above
else
  # (a) the pkg/pack inverse no longer does a bare blind `pacman -Rns $set` with
  #     swallowed stderr — it routes through a removable-subset filter that
  #     surfaces pacman's error. Require the dedicated helper AND that the inverse
  #     no longer pipes pacman -Rns straight to /dev/null 2>&1.
  if grep -qE '_revert_pkgset' <<<"$_ra_code"; then
    _v_ok "revert-all routes pack removal through a shared-dep-aware _revert_pkgset (no atomic abort on a shared dep, REV-04)"
  else
    _v_fail "revert-all has no _revert_pkgset — a recorded dep still required by another pack aborts the whole -Rns transaction (REV-04)"
  fi
  if grep -qE 'pacman -Rns[^|]*2>&1[[:space:]]*>/dev/null' <<<"$_ra_code"; then
    _v_ok "revert-all captures pacman -Rns stderr (the real failure reason is surfaced, not swallowed) (REV-04)"
  else
    _v_fail "revert-all does not capture pacman -Rns stderr — a removal failure stays a generic 'failed' (REV-04)"
  fi
  # the removable-subset filter must consult installed reverse-deps ('Required By').
  grep -q 'Required By' <<<"$_ra_code" \
    && _v_ok "revert-all filters to packages not required by an outsider (Required By gate) (REV-04)" \
    || _v_fail "revert-all never inspects 'Required By' — it cannot skip a still-needed shared dep (REV-04)"
  # (b) the per-feature filter must ALSO match pack-tagged side-effect rows, else
  #     a pack's service/group/lua rows linger after `iictl pack remove`.
  grep -q '_row_in_filter' <<<"$_ra_code" \
    && _v_ok "revert-all's feature filter sweeps pack-tagged side-effect rows via _row_in_filter (REV-04)" \
    || _v_fail "revert-all's feature filter matches only F_target — pack-tagged side-effect rows are never swept (REV-04)"
fi
if [[ ! -f "$MUT" ]]; then
  _v_fail "mutator.sh not staged — pack side-effect rows cannot carry the pack tag (REV-04)"
elif [[ ! -f "$PK" ]]; then
  : # pack engine absence already failed above
else
  _mut_code="$(grep -vE '^[[:space:]]*#' "$MUT")"
  _pk_code2="$(grep -vE '^[[:space:]]*#' "$PK")"
  # the pack engine exports II_PACK_TAG around the post-add hook…
  grep -q 'II_PACK_TAG' <<<"$_pk_code2" \
    && _v_ok "pack engine exports II_PACK_TAG around the post-add hook (side effects carry the pack tag) (REV-04)" \
    || _v_fail "pack engine never sets II_PACK_TAG — post-add side effects record no pack tag and linger after remove (REV-04)"
  # …and the mutators stamp that tag onto the side-effect ledger rows.
  grep -q 'II_PACK_TAG\|_ii_pack_tag' <<<"$_mut_code" \
    && _v_ok "mutators stamp the pack tag (II_PACK_TAG) onto recorded side-effect rows (REV-04)" \
    || _v_fail "mutators ignore II_PACK_TAG — pack side-effect rows are not pack-tagged and revert-all can't sweep them (REV-04)"
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

step "swapfile resume + cmdline fallback (INST-02)"
# A swapfile cannot be resumed from by PATH: the kernel needs resume=<block
# device> + resume_offset=<physical offset>. ii-prepare-bootloader used to emit
# `resume=$(awk '{print $1}' <<< swap)` verbatim → `resume=/swapfile`, silently
# breaking hibernation; the cmdline FALLBACK in ii-finish-systemd-boot dropped
# LUKS cryptdevice= and resume= entirely; a non-UUID crypttab source produced a
# malformed `cryptdevice=UUID=/dev/…`. This guards all three on the SOURCE
# scripts (they run inside the target chroot, not in build/), plus table-tests
# the pure swap-source classifier extracted from ii-prepare-bootloader.
_PB="$SCRIPTS/runtime/ii-prepare-bootloader"
_FB="$SCRIPTS/runtime/ii-finish-systemd-boot"
if [[ ! -f "$_PB" || ! -f "$_FB" ]]; then
  _v_fail "ii-prepare-bootloader / ii-finish-systemd-boot missing — INST-02 guard can't run"
else
  _inst02_ok=1
  # (a) neither script emits the swapfile field-1 PATH bare as resume=. The old
  #     line was `resume=$(awk '{print $1}' <<< "$swap")`; classification must
  #     gate it now. Flag any resume= built directly from the swap field.
  if grep -E 'resume=\$\(awk .*\$1.*<<< *"?\$swap' "$_PB" "$_FB" | grep -qv '^[^:]*:[[:space:]]*#'; then
    _v_fail "a bootloader script still emits the swap field-1 verbatim as resume= → a swapfile path breaks resume (INST-02)"; _inst02_ok=0
  fi
  # (b) the swapfile branch must compute resume_offset= (filefrag / btrfs).
  grep -q 'resume_offset=' "$_PB" \
    || { _v_fail "ii-prepare-bootloader emits no resume_offset= — swapfile hibernation can't resume (INST-02)"; _inst02_ok=0; }
  grep -qE 'filefrag|map-swapfile' "$_PB" \
    || { _v_fail "ii-prepare-bootloader computes no swapfile offset (filefrag/btrfs) (INST-02)"; _inst02_ok=0; }
  # (c) the cmdline fallback in ii-finish-systemd-boot must carry LUKS + resume.
  grep -q 'cryptdevice=' "$_FB" \
    || { _v_fail "ii-finish-systemd-boot cmdline fallback drops LUKS cryptdevice= → a LUKS fallback entry can't unlock (INST-02)"; _inst02_ok=0; }
  grep -qE '(^|[^_])resume=' "$_FB" \
    || { _v_fail "ii-finish-systemd-boot cmdline fallback drops resume= → fallback entry can't hibernate-resume (INST-02)"; _inst02_ok=0; }
  # (d) crypttab source emitted VERBATIM, never re-wrapped as UUID=$stripped.
  if grep -qE 'cryptdevice=UUID=\$\{?u' "$_PB"; then
    _v_fail "ii-prepare-bootloader still wraps the crypttab source as UUID=\$u → malformed for a non-UUID source (INST-02)"; _inst02_ok=0
  fi
  # (e) table-test the pure classifier extracted from the source (no side effects).
  if _cls=$(awk '/^ii_classify_swap_source\(\)/{p=1} p{print} p&&/^}/{exit}' "$_PB") && [[ -n "$_cls" ]]; then
    if ( eval "$_cls"
         [[ "$(ii_classify_swap_source 'UUID=x')"   == partition ]] &&
         [[ "$(ii_classify_swap_source '/dev/sda2')" == partition ]] &&
         [[ "$(ii_classify_swap_source 'LABEL=swap')" == partition ]] &&
         [[ "$(ii_classify_swap_source '/swapfile')" == file ]] &&
         [[ "$(ii_classify_swap_source '/var/swapfile')" == file ]] ); then
      _v_ok "ii_classify_swap_source maps UUID/LABEL/dev→partition, paths→file (INST-02)"
    else
      _v_fail "ii_classify_swap_source misclassifies a swap source (INST-02)"; _inst02_ok=0
    fi
  else
    _v_fail "could not extract ii_classify_swap_source from ii-prepare-bootloader (INST-02)"; _inst02_ok=0
  fi
  (( _inst02_ok )) && _v_ok "bootloader scripts never emit a swapfile path bare as resume=; fallback carries LUKS+resume (INST-02)"
fi

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
  # (d) the nvidia-stash + git-freshness artifact pick goes through
  #     _newest_cached_exact, whose body skips .sig (and -debug) so head -1 can't
  #     pick a detached signature (BUILD-01) or a dash-prefix sibling (PB-02).
  grep -F -A9 '_newest_cached_exact() {' "$_PREBUILD" | grep -q '\*\.sig' \
    || { _v_fail "prebuild _newest_cached_exact no longer excludes .sig → head -1 could stage a signature"; _pb_sig_ok=0; }
  grep -F 'nvidia stash' "$_PREBUILD" >/dev/null && \
  grep -A12 'stage AUR nvidia packages' "$_PREBUILD" | grep -q '_newest_cached_exact' \
    || { _v_fail "prebuild nvidia-stash no longer uses _newest_cached_exact (.sig/sibling-safe artifact pick)"; _pb_sig_ok=0; }
  (( _pb_sig_ok )) && _v_ok "prebuild filters detached .sig from every repo-add/stash glob (BUILD-01)"
fi

step "prebuild exact-name matching + prune (BUILD-03)"
# A `$REPO_PATH/$name-*` / `$REPO_PATH/$pkg-*` prefix glob matches dash-prefix
# SIBLINGS: building `python` could delete or misread a cached `python-build`
# (PB-02). The verify loop must match the repo DB by FIXED STRING, not by
# interpolating $pkg raw into an ERE (+/. in a name then mis-match — PB-03). The
# AUR RPC must be cached so a transient second lookup isn't fatal for a split
# pkgbase (PB-04). The cache must be pruned of obsolete members after a
# successful run, else [ii-extra] (ordered before core/extra) shadows officials
# (PB-05). Static grep on the host-side source.
if [[ ! -f "$_PREBUILD" ]]; then
  : # already failed above
else
  _pb_name_ok=1
  # (PB-02) no bare `$REPO_PATH/$<var>-`* prefix glob survives — every artifact
  # lookup/removal goes through the exact-name helpers instead.
  if grep -nE '\$REPO_PATH/\$[A-Za-z_][A-Za-z0-9_]*-["'\'']?\*' "$_PREBUILD" | grep -qvE '^\s*[0-9]+:\s*#'; then
    _v_fail "prebuild still has a \$REPO_PATH/\$name-* prefix glob → dash-prefix sibling collision (PB-02)"; _pb_name_ok=0
  fi
  # exact-name helpers exist and are used for cache read / removal / newest-pick
  for fn in _pkg_name_from_file _rm_cached_exact _newest_cached_exact; do
    grep -qF "$fn() {" "$_PREBUILD" || { _v_fail "prebuild missing exact-name helper $fn (PB-02)"; _pb_name_ok=0; }
  done
  grep -qF '_rm_cached_exact "$name"' "$_PREBUILD" \
    || { _v_fail "prebuild staging no longer removes by exact name (_rm_cached_exact) (PB-02)"; _pb_name_ok=0; }
  # (PB-03) verify is a fixed-string DB-name set lookup, NOT a `$pkg`-as-ERE grep
  if grep -qE 'grep -E "\^\$pkg-' "$_PREBUILD"; then
    _v_fail "prebuild verify greps \$pkg raw into an ERE → +/. names mis-match (PB-03)"; _pb_name_ok=0
  fi
  grep -qF 'DB_NAMES[' "$_PREBUILD" \
    || { _v_fail "prebuild verify no longer uses a fixed-string DB-name set (PB-03)"; _pb_name_ok=0; }
  # (PB-04) the AUR RPC is memoised (one fetch shared by _aur_ver + _aur_base)
  grep -qF '_aur_rpc() {' "$_PREBUILD" && grep -qF 'AUR_JSON[' "$_PREBUILD" \
    || { _v_fail "prebuild no longer caches the AUR RPC JSON → transient 2nd RPC fatal for split pkgbase (PB-04)"; _pb_name_ok=0; }
  # (PB-05) obsolete cache members are pruned after a successful run
  grep -qiF 'prune obsolete' "$_PREBUILD" && grep -qF 'KEEP[' "$_PREBUILD" \
    || { _v_fail "prebuild no longer prunes obsolete cache members → [ii-extra] can shadow officials (PB-05)"; _pb_name_ok=0; }
  (( _pb_name_ok )) && _v_ok "prebuild matches by exact name + fixed-string DB + caches RPC + prunes (BUILD-03)"
fi

step "resolve-deps dependency discovery (BUILD-02)"
# resolve-deps.py scrapes upstream's sdata/dist-arch/*/PKGBUILD into
# packages.x86_64. The dependency-only meta-packages (no package() body) used to
# be found ONLY via a hardcoded METAPKGS list; the structural rglob skipped them.
# An upstream bump that ADDS such a meta-package would then silently drop its
# depends from packages.x86_64 — a missing-dependency ISO with no error, and
# `just update` bumps the pin without re-checking. Two guards (static, no root,
# no network; mirrors the first_run.txt cross-check pattern):
#   1. layout drift — the dist-arch PKGBUILD root exists, is non-empty, and every
#      hardcoded METAPKGS entry still resolves to a real PKGBUILD (an upstream
#      rename screams HERE, not at a user's broken install).
#   2. structural discovery — resolve-deps.py must discover meta-packages by the
#      illogical-impulse- pkgname prefix (not be reverted to hardcoded-only) and
#      parse_depends must handle the append form (depends+=).
_DISTARCH="$DOTS/sdata/dist-arch"
_RESOLVE="$TOOLS/resolve-deps.py"
if [[ ! -d "$_DISTARCH" ]]; then
  _v_fail "dist-arch PKGBUILD root missing ($_DISTARCH) — resolve-deps.py scrapes nothing → packages.x86_64 loses every upstream dep (BUILD-02)"
else
  mapfile -t _da_pkgbuilds < <(find "$_DISTARCH" -name PKGBUILD -type f 2>/dev/null)
  if (( ${#_da_pkgbuilds[@]} == 0 )); then
    _v_fail "dist-arch root has no PKGBUILDs ($_DISTARCH) — upstream layout drifted; resolve-deps.py would emit empty lists (BUILD-02)"
  else
    _v_ok "dist-arch PKGBUILD root present (${#_da_pkgbuilds[@]} PKGBUILDs) (BUILD-02)"
    # Every hardcoded METAPKGS entry must still resolve to a real PKGBUILD.
    mapfile -t _metapkgs < <(
      sed -nE '/^METAPKGS\s*=\s*\[/,/^\]/p' "$_RESOLVE" \
        | grep -oE '"[^"]+"' | tr -d '"'
    )
    if (( ${#_metapkgs[@]} == 0 )); then
      _v_warn "could not parse METAPKGS from resolve-deps.py — drift cross-check skipped (BUILD-02)"
    else
      _meta_miss=()
      for _m in "${_metapkgs[@]}"; do
        [[ -f "$_DISTARCH/$_m/PKGBUILD" ]] || _meta_miss+=("$_m")
      done
      (( ${#_meta_miss[@]} == 0 )) \
        && _v_ok "all ${#_metapkgs[@]} METAPKGS entries resolve to a real dist-arch PKGBUILD (BUILD-02)" \
        || _v_fail "METAPKGS entries missing from dist-arch (upstream renamed/removed): ${_meta_miss[*]} — their depends would never reach packages.x86_64 (BUILD-02)"
    fi
  fi
fi
# Structural-discovery guards: the regression is reverting to hardcoded-only
# discovery (rglob limited to package()-bearing PKGBUILDs) or a parse_depends that
# only reads the first literal depends=().
if [[ ! -f "$_RESOLVE" ]]; then
  _v_fail "tools/resolve-deps.py missing — no upstream dependency scraping (BUILD-02)"
else
  grep -Eq 'name\.startswith\(META_PREFIX\)' "$_RESOLVE" \
    && _v_ok "resolve-deps.py discovers dependency-only meta-packages structurally by pkgname prefix (BUILD-02)" \
    || _v_fail "resolve-deps.py no longer does structural meta-package discovery — an upstream-added meta-package would silently drop its depends (BUILD-02)"
  grep -Eq 'depends.*\\\+\?=' "$_RESOLVE" \
    && _v_ok "resolve-deps.py parse_depends handles append/arch-suffixed depends (BUILD-02)" \
    || _v_warn "resolve-deps.py parse_depends may not handle depends+= / arch-suffixed arrays (BUILD-02)"
fi

step "archiso customize_airootfs hook guard (BUILD-05)"
# chroot.sh is staged as /root/customize_airootfs.sh and run by mkarchiso via a
# mechanism mkarchiso ITSELF warns is deprecated ("Support for it will be removed
# in a future archiso version"). archiso is pulled UNPINNED from the host. If a
# host bump drops the hook, the keyring/paru/wheelhouse/liveuser-seed/microcode-
# stash/sanity-gate bootstrap SILENTLY stops running — the ISO still builds but
# ships broken. Two halves, mirroring the CI-0x split:
#   (a) the builder container PINS archiso AND fails its own build if the pinned
#       mkarchiso no longer runs the hook (containers/builder.Dockerfile).
#   (b) scripts/mkiso.sh re-checks the *installed* mkarchiso at build time and
#       dies loudly if the hook reference is gone.
# Plus: when an installed mkarchiso is on this validate host's PATH (it is on the
# Arch CI container, but NOT necessarily a contributor laptop), assert the hook
# directly. Static greps on tracked sources + a best-effort live binary probe.
_DF="$ROOT/containers/builder.Dockerfile"
_MKISO="$SCRIPTS/mkiso.sh"
_b5_ok=1
# (a) Dockerfile must pin archiso (archiso=… or an ARCHISO_PIN ARG) ...
if [[ ! -f "$_DF" ]]; then
  _v_fail "containers/builder.Dockerfile missing — BUILD-05 archiso pin unverifiable"; _b5_ok=0
else
  if grep -Eq 'archiso=\$\{?ARCHISO_PIN' "$_DF" || grep -Eq 'ARG[[:space:]]+ARCHISO_PIN=' "$_DF" || grep -Eq 'archiso=[0-9]' "$_DF"; then
    _v_ok "builder.Dockerfile pins archiso (BUILD-05)"
  else
    _v_fail "builder.Dockerfile pulls archiso UNPINNED — a host bump dropping the customize_airootfs.sh hook would silently ship a broken ISO (BUILD-05)"; _b5_ok=0
  fi
  # ... and re-assert the hook against the pinned mkarchiso at image-build time.
  if grep -q 'customize_airootfs' "$_DF"; then
    _v_ok "builder.Dockerfile re-checks mkarchiso runs customize_airootfs.sh at image build (BUILD-05)"
  else
    _v_fail "builder.Dockerfile does not assert the pinned mkarchiso still runs customize_airootfs.sh (BUILD-05)"; _b5_ok=0
  fi
fi
# (b) mkiso.sh must guard the installed mkarchiso before running it.
if [[ ! -f "$_MKISO" ]]; then
  _v_fail "scripts/mkiso.sh missing — BUILD-05 runtime guard unverifiable"; _b5_ok=0
elif grep -q 'customize_airootfs' "$_MKISO"; then
  _v_ok "mkiso.sh asserts the installed mkarchiso still runs customize_airootfs.sh before building (BUILD-05)"
else
  _v_fail "mkiso.sh runs an unpinned mkarchiso without checking it still runs customize_airootfs.sh — a silent hook drop ships a broken ISO (BUILD-05)"; _b5_ok=0
fi
# Live probe (best-effort; skipped where mkarchiso isn't installed, e.g. a laptop).
if command -v mkarchiso >/dev/null 2>&1; then
  if grep -q 'customize_airootfs\.sh' "$(command -v mkarchiso)" 2>/dev/null; then
    _v_ok "installed mkarchiso ($(command -v mkarchiso)) runs customize_airootfs.sh (BUILD-05, live probe)"
  else
    _v_fail "installed mkarchiso ($(command -v mkarchiso)) NO LONGER references customize_airootfs.sh — the chroot bootstrap would not run (BUILD-05); pin/downgrade archiso or port chroot.sh off the deprecated hook"; _b5_ok=0
  fi
else
  _v_warn "mkarchiso not on PATH — BUILD-05 live hook probe skipped (the Dockerfile pin + mkiso.sh guard still apply; this host can't build an ISO anyway)"
fi
(( _b5_ok )) && _v_ok "BUILD-05 archiso/customize_airootfs hook guard intact (pin + image-build assert + mkiso.sh runtime guard)"

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

step "unattended install→boot smoke wiring (TEST-01)"
# TEST-01 adds an unattended install smoke (install-smoke.sh, `just smoke
# --installed`): autologin live → headless Calamares from a scripted seed →
# boot the installed disk → re-probe a graphical session (Calamares' own
# shellprocess@verify-install ii-verify gate must have passed, or the install
# aborts). It rides a live-only seam — a dedicated `ii_autoinstall` boot entry
# read by the live-only execs.lua hook, driving the live-only ii-autoinstall
# helper. All of that is purged on install (ii-verify) and never reaches an
# installed user. This check asserts each link of that chain is wired, so a
# later edit can't silently sever the install smoke. Static greps.
_ISMOKE="$ROOT/scripts/install-smoke.sh"
if [[ ! -f "$_ISMOKE" ]]; then
  _v_fail "scripts/install-smoke.sh missing — the unattended install smoke (TEST-01) is gone"
else
  # (a) same CI-03 KVM fast-fail stance as smoke.sh — no silent TCG hang.
  if grep -q 'die "KVM required for the install smoke' "$_ISMOKE" && grep -q '/dev/kvm' "$_ISMOKE"; then
    _v_ok "install-smoke.sh fails fast on missing /dev/kvm (CI-03 stance) (TEST-01)"
  else
    _v_fail "install-smoke.sh does not fail fast on missing /dev/kvm — a KVM-less run hangs to its timeout (TEST-01/CI-03)"
  fi
  # (b) it must assert the install verdict AND re-probe the installed boot.
  grep -q 'II_RESULT' "$_ISMOKE" && grep -q 'distinct colors' "$_ISMOKE" \
    && _v_ok "install-smoke.sh asserts an install verdict + re-probes the installed graphical session (TEST-01)" \
    || _v_fail "install-smoke.sh must read the install verdict (II_RESULT) and probe the installed boot's framebuffer (TEST-01)"
fi
# (c) `just smoke --installed` must route to the install smoke, leaving the
#     live smoke (bare `just smoke`) untouched.
if grep -qE 'install-smoke\.sh' "$ROOT/justfile" && grep -q 'smoke.sh' "$ROOT/justfile"; then
  _v_ok "justfile routes 'just smoke --installed' to install-smoke.sh, keeps the live smoke (TEST-01)"
else
  _v_fail "justfile does not route '--installed' to install-smoke.sh (or dropped the live smoke) (TEST-01)"
fi
# (d) the live-only trigger chain: dedicated boot entry → execs.lua hook → helper.
_AI_ENTRY="$OVERLAY/efiboot/loader/entries/05-illogical-impulse-autoinstall.conf"
if [[ -f "$_AI_ENTRY" ]] && grep -q 'ii_autoinstall' "$_AI_ENTRY"; then
  _v_ok "dedicated 'Unattended install' boot entry carries ii_autoinstall (TEST-01)"
else
  _v_fail "missing/empty ii_autoinstall boot entry (overlay/efiboot/.../05-*autoinstall.conf) — the smoke can't reach the unattended path (TEST-01)"
fi
_AI_EXECS="$AIROOTFS/etc/skel-live/.config/hypr/custom/execs.lua"
[[ -f "$_AI_EXECS" ]] || _AI_EXECS="$OVERLAY/skel-live/.config/hypr/custom/execs.lua"
if [[ -f "$_AI_EXECS" ]] && grep -q 'ii_autoinstall' "$_AI_EXECS" && grep -q 'ii-autoinstall' "$_AI_EXECS"; then
  _v_ok "live execs.lua recognizes ii_autoinstall → runs ii-autoinstall (TEST-01)"
else
  _v_fail "live execs.lua does not branch on ii_autoinstall to run ii-autoinstall (TEST-01)"
fi
_AI_HELPER="$AIROOTFS/usr/local/bin/ii-autoinstall"
[[ -f "$_AI_HELPER" ]] || _AI_HELPER="$ROOT/scripts/runtime/ii-autoinstall"
if [[ -f "$_AI_HELPER" ]]; then
  bash -n "$_AI_HELPER" 2>/dev/null \
    && _v_ok "ii-autoinstall live helper present and syntactically valid (TEST-01)" \
    || _v_fail "ii-autoinstall has a syntax error (TEST-01)"
else
  _v_fail "ii-autoinstall live helper missing (scripts/runtime/ii-autoinstall) (TEST-01)"
fi
# (e) ii-autoinstall MUST be purged on install (live-only; Iron Law) — it is in
#     ii-verify's named-file purge loop alongside the other ISO-only helpers.
_IV="$AIROOTFS/usr/local/bin/ii-verify"
[[ -f "$_IV" ]] || _IV="$ROOT/scripts/runtime/ii-verify"
if [[ -f "$_IV" ]] && grep -q 'ii-autoinstall' "$_IV"; then
  _v_ok "ii-verify purges ii-autoinstall from the installed system (live-only) (TEST-01)"
else
  _v_fail "ii-verify does not purge ii-autoinstall — a live-only install helper would leak onto the installed system (TEST-01/Iron Law)"
fi

step "list files end with a trailing newline (BUILD-04)"
# The prepare-time list readers are now newline-agnostic
# (`while read … || [[ -n "$line" ]]`, scripts/prepare.d/30-skel.sh +
# 40-packages.sh), so a no-trailing-newline list keeps its last entry. This is
# the belt-and-suspenders half: a maintainer/profile-editable manifest or fetch
# list that does NOT end in '\n' is the bug-class (a final package not installed,
# a final tree not cloned) — flag it at build time so an editor that strips the
# trailing newline is caught here, not silently mis-built. Static, source-only.
_nl_files=()
shopt -s nullglob
for _lf in "$PACKAGES"/*.list "$OVERLAY/skel-distro.fetch"; do
  [[ -f "$_lf" ]] && _nl_files+=("$_lf")
done
for _pf in "$PROFILES"/*/packages.list "$PROFILES"/*/fetch.list; do
  [[ -f "$_pf" ]] && _nl_files+=("$_pf")
done
shopt -u nullglob
_nl_bad=0
for _lf in "${_nl_files[@]}"; do
  # A trailing newline means the last byte is '\n'. Empty files are fine.
  if [[ -s "$_lf" && -n "$(tail -c1 "$_lf")" ]]; then
    _v_fail "list file lacks a trailing newline: ${_lf#$ROOT/} — an editor stripped it; the prepare readers tolerate this but re-add the newline (BUILD-04)"
    _nl_bad=$((_nl_bad+1))
  fi
done
if (( ${#_nl_files[@]} == 0 )); then
  _v_warn "no list files found to newline-check (packages/*.list, profile lists, skel-distro.fetch)"
elif (( _nl_bad == 0 )); then
  _v_ok "${#_nl_files[@]} list file(s) end with a trailing newline (BUILD-04)"
fi

step "ii-verify covers every installed kernel (INST-03)"
# Bug-class guard (issue #71): ii-verify used to hardcode the `linux`
# vmlinuz/initramfs(.img/-fallback.img) triple and only repair linux.preset.
# But goodies.list ships linux-lts and ii-prepare-bootloader builds a
# default+fallback initramfs for EVERY pkgbase in /usr/lib/modules/*/ (writing
# each path into .ii-boot-state.json's expected_paths). With the hardcoded
# triple a broken linux-lts initramfs passed verification and the LTS rescue
# entry booted to a broken image — the exact failure the "always build fallback"
# design exists to catch. So ii-verify MUST (a) derive the kernel set
# dynamically (from .ii-boot-state.json's expected_paths and/or
# /usr/lib/modules/*/pkgbase, mirroring ii-prepare-bootloader) and (b) NOT carry
# a hardcoded single-`linux` artefact triple. Comments stripped first so this
# header's prose can neither satisfy nor trip the code greps.
IVERIFY="$AIROOTFS/usr/local/bin/ii-verify"
if [[ ! -f "$IVERIFY" ]]; then
  _v_fail "ii-verify missing from airootfs — INST-03 guard can't run"
else
  _iv_code="$(grep -vE '^[[:space:]]*#' "$IVERIFY")"
  # (a) it reads .ii-boot-state.json's expected_paths (not merely its existence).
  if grep -q '.ii-boot-state.json' <<<"$_iv_code" \
     && grep -qE 'vmlinuz-' <<<"$_iv_code" \
     && grep -q 'expected_paths' "$IVERIFY"; then
    _v_ok "ii-verify reads .ii-boot-state.json's expected_paths to derive the kernel set (INST-03)"
  else
    _v_fail "ii-verify does not read .ii-boot-state.json's expected_paths — it can't validate every kernel's artefacts (INST-03)"
  fi
  # (b) it enumerates kernels dynamically via /usr/lib/modules/*/pkgbase (the
  #     same source ii-prepare-bootloader uses), as the fallback/cross-check.
  grep -q '/usr/lib/modules/\*/' <<<"$_iv_code" && grep -q 'pkgbase' <<<"$_iv_code" \
    && _v_ok "ii-verify enumerates kernels via /usr/lib/modules/*/pkgbase (mirrors ii-prepare-bootloader) (INST-03)" \
    || _v_fail "ii-verify does not enumerate /usr/lib/modules/*/pkgbase — a non-default kernel set goes unverified (INST-03)"
  # (c) the hardcoded single-`linux` artefact triple must be gone. The old code
  #     literally checked vmlinuz-linux / initramfs-linux.img /
  #     initramfs-linux-fallback.img; any of those LITERAL tokens means the
  #     regression is back. Per-kernel code uses vmlinuz-$kb / -$pkgbase instead.
  if grep -qE '(vmlinuz-linux\b|initramfs-linux\.img|initramfs-linux-fallback\.img)' <<<"$_iv_code"; then
    _v_fail "ii-verify still references the hardcoded 'linux' artefact triple (vmlinuz-linux/initramfs-linux*.img) — linux-lts artefacts go unchecked (INST-03)"
  else
    _v_ok "ii-verify has no hardcoded single-'linux' artefact triple (per-kernel checks instead) (INST-03)"
  fi
fi

step "historic-bug / Iron-Law coverage (IMMUNE-01)"
# Cluster of small guards for documented historic bug-classes + Iron-Law
# invariants that previously had NO validate.sh check, so a regression shipped
# green. One focused check per item; mirrors the NVSTASH/cups grep patterns.

# (1) welcomeStyleCalamares — must be `true` in branding.desc; `false` hides
#     productWelcome (the welcome.png hero). The stylesheet.qss formerly carried
#     an INERT wrong `welcomeStyleCalamares: false` (it is a branding key, no-op
#     in a .qss) — a misleading drift now pinned to match branding.desc.
_BRAND_DIR="$AIROOTFS/etc/calamares/branding/illogical-impulse"
_BDESC="$_BRAND_DIR/branding.desc"
if [[ -f "$_BDESC" ]] && grep -qE '^[[:space:]]*welcomeStyleCalamares:[[:space:]]*true[[:space:]]*$' "$_BDESC"; then
  _v_ok "branding.desc welcomeStyleCalamares: true (productWelcome shown)"
else
  _v_fail "branding.desc welcomeStyleCalamares is not 'true' — productWelcome (welcome.png) is hidden"
fi
_BQSS="$_BRAND_DIR/stylesheet.qss"
if [[ -f "$_BQSS" ]] && grep -qE '^[[:space:]]*welcomeStyleCalamares:[[:space:]]*false' "$_BQSS"; then
  _v_fail "stylesheet.qss still carries the inert wrong 'welcomeStyleCalamares: false' — match branding.desc (true) so the value never misleads"
else
  _v_ok "stylesheet.qss has no inert wrong welcomeStyleCalamares: false"
fi

# (2) services-systemd module schema is `units:`, NOT `services:`/`targets:`.
#     The wrong keys make Calamares silently drop every entry (no service
#     enabled). Strip comments first so the conf's own schema-note prose can
#     neither satisfy nor trip the grep.
_SSYS="$AIROOTFS/etc/calamares/modules/services-systemd.conf"
if [[ ! -f "$_SSYS" ]]; then
  _v_fail "services-systemd.conf missing from staged airootfs"
else
  _ssys_code="$(grep -vE '^[[:space:]]*#' "$_SSYS")"
  if grep -qE '^[[:space:]]*units:' <<<"$_ssys_code"; then
    _v_ok "services-systemd.conf uses the 'units:' schema"
  else
    _v_fail "services-systemd.conf lacks 'units:' — Calamares silently drops every entry (no service enabled)"
  fi
  if grep -qE '^[[:space:]]*(services|targets):' <<<"$_ssys_code"; then
    _v_fail "services-systemd.conf uses the wrong 'services:'/'targets:' keys — Calamares ignores them; convert to 'units:'"
  else
    _v_ok "services-systemd.conf has no wrong services:/targets: keys"
  fi
fi

# (3) ii-post-install MUST remove the live gnupg tmpfs mount unit. If it
#     survives, the tmpfs hides the real on-disk keyring and pacman signature
#     verification fails on the installed system.
_POSTI="$AIROOTFS/usr/local/bin/ii-post-install"
if [[ -f "$_POSTI" ]] && grep -q 'etc-pacman.d-gnupg.mount' "$_POSTI"; then
  _v_ok "ii-post-install removes the live gnupg tmpfs mount (keyring survives)"
else
  _v_fail "ii-post-install no longer removes etc-pacman.d-gnupg.mount — the live tmpfs would hide the installed keyring"
fi

# (4) installer purge is DATA-DRIVEN from installer.list. 40-packages.sh stages
#     the baked installer-only names to installer-purge.list; ii-post-install
#     reads that file (not a hardcoded `calamares kpmcore`), so a third
#     installer.list entry can't leak onto the installed target. Guard both
#     halves: the staged list exists + covers installer.list, and
#     ii-post-install consumes it.
_IPURGE_STAGED="$AIROOTFS/usr/share/illogical-impulse/installer-purge.list"
_ILIST="$PACKAGES/installer.list"
if [[ ! -f "$_IPURGE_STAGED" ]]; then
  _v_fail "installer-purge.list not staged — ii-post-install's purge isn't data-driven from installer.list"
elif [[ -f "$_ILIST" ]]; then
  _ip_miss=0
  while IFS= read -r _ipkg; do
    _ipkg="${_ipkg%%#*}"; _ipkg="${_ipkg//[[:space:]]/}"
    [[ -n "$_ipkg" ]] || continue
    grep -qxF "$_ipkg" "$_IPURGE_STAGED" || { _v_fail "installer.list pkg '$_ipkg' missing from staged installer-purge.list — it would leak onto the target"; _ip_miss=$((_ip_miss + 1)); }
  done < "$_ILIST"
  (( _ip_miss == 0 )) && _v_ok "installer-purge.list covers every installer.list pkg (purge data-driven)"
fi
if [[ -f "$_POSTI" ]] && grep -q 'installer-purge.list' "$_POSTI"; then
  _v_ok "ii-post-install reads installer-purge.list (purge stays in lockstep with installer.list)"
else
  _v_fail "ii-post-install does not read installer-purge.list — the purge is hardcoded and can drift from installer.list"
fi

# (5) the SECOND hardcoded copy of upstream's firstRunFileContent — the
#     fail-safe seed in ii-post-install — must stay byte-equal to upstream's
#     string (the skel seed has its own guard; this literal was unguarded).
_FRUN_QML="$DOTS/dots/.config/quickshell/ii/services/FirstRunExperience.qml"
if [[ ! -f "$_POSTI" ]]; then
  _v_fail "ii-post-install missing — can't guard the fail-safe firstRun literal"
elif [[ ! -f "$_FRUN_QML" ]]; then
  _v_warn "upstream FirstRunExperience.qml not found — fail-safe firstRun literal cross-check skipped"
else
  _frun_up=$(sed -nE 's/.*firstRunFileContent:[[:space:]]*"([^"]*)".*/\1/p' "$_FRUN_QML")
  # The literal is `printf "<text>\n" > "$FRUN"` in ii-post-install; pull the
  # quoted text and drop the trailing \n to compare against upstream's value.
  _frun_post=$(grep -oE 'printf "[^"]*" > "\$FRUN"' "$_POSTI" | sed -E 's/^printf "//; s/" > "\$FRUN"$//; s/\\n$//')
  if [[ -z "$_frun_up" ]]; then
    _v_warn "could not parse firstRunFileContent from FirstRunExperience.qml — fail-safe literal cross-check skipped"
  elif [[ -z "$_frun_post" ]]; then
    _v_fail "ii-post-install's fail-safe first_run.txt printf literal not found in the expected form — can't verify it matches upstream"
  elif [[ "$_frun_post" == "$_frun_up" ]]; then
    _v_ok "ii-post-install fail-safe firstRun literal matches upstream's firstRunFileContent"
  else
    _v_fail "ii-post-install fail-safe firstRun literal drifted from upstream's firstRunFileContent (got '$_frun_post', upstream '$_frun_up')"
  fi
fi

# (6) the banned `((var++))` idiom: post-increment of a zero variable returns 1,
#     so under `set -e` it silently kills the script (cost a real two-kernel
#     install). Forbid it in the runtime/prepare scripts; use var=$((var + 1)).
#     Scan the SOURCE trees (not the staged copy) and ignore comments so the
#     ii-prepare-bootloader "NOT ((copied++))" caution doesn't self-trip.
_pp_hits=0
while IFS= read -r _ppfile; do
  [[ -f "$_ppfile" ]] || continue
  if grep -vE '^[[:space:]]*#' "$_ppfile" | grep -qE '\(\([[:alnum:]_]+(\+\+|--)\)\)|\(\((\+\+|--)[[:alnum:]_]+\)\)'; then
    _v_fail "banned post/pre-(in|de)crement '((var++))' in ${_ppfile#"$ROOT"/} — returns 1 on a 0 value and set -e kills the script; use var=\$((var + 1))"
    _pp_hits=$((_pp_hits + 1))
  fi
done < <(find "$SCRIPTS/runtime" "$SCRIPTS/prepare.d" -maxdepth 1 -type f 2>/dev/null)
(( _pp_hits == 0 )) && _v_ok "no banned '((var++))' idiom in runtime/ + prepare.d/ scripts"

step "runtime + chroot scripts syntax"
# Every airootfs runtime helper must `bash -n` clean. The loop historically
# omitted ii-ensure-venv, ii-build-wheelhouse and ii-live-welcome — three real
# shipped helpers — so a syntax error in any of them passed validate green
# (IMMUNE-01 syntax-loop-misses-three-scripts). They are now in the list.
for sc in "$AIROOTFS/usr/local/bin/"ii-session \
          "$AIROOTFS/usr/local/bin/"ii-launch-installer \
          "$AIROOTFS/usr/local/bin/"iictl \
          "$AIROOTFS/usr/local/bin/"ii-post-install \
          "$AIROOTFS/usr/local/bin/"ii-prepare-bootloader \
          "$AIROOTFS/usr/local/bin/"ii-finish-systemd-boot \
          "$AIROOTFS/usr/local/bin/"ii-verify \
          "$AIROOTFS/usr/local/bin/"ii-ensure-venv \
          "$AIROOTFS/usr/local/bin/"ii-build-wheelhouse \
          "$AIROOTFS/usr/local/bin/"ii-live-welcome \
          "$AIROOTFS/root/"customize_airootfs.sh; do
  [[ -f "$sc" ]] || { _v_fail "missing: $sc"; continue; }
  [[ "$(head -c2 "$sc")" == "#!" ]] || _v_fail "no shebang: $(basename "$sc")"
  bash -n "$sc" 2>/dev/null && _v_ok "$(basename "$sc")" || _v_fail "$(basename "$sc") syntax error"
done

step "nvidia PCI-id classifier (HW-01)"
# The open/legacy/nouveau classifier lives in a PURE lib (nvidia-classify.sh,
# sourced by ii-post-install) precisely so it can be unit-tested here in
# isolation — a boundary regression must fail CI, not silently break driver
# install for a whole GPU generation. We source the STAGED airootfs copy (the
# one the ISO actually ships) and run it against a table of known
# (device-id → expected-variant) cases that pin every band boundary:
#   Kepler/Maxwell  0x1300  (legacy floor)   |  Pascal/Volta/Turing 0x1E00 (open floor)
# Flip a boundary id's expectation (or move a *_FLOOR in nvidia-classify.sh) and
# this step goes red. To extend: update the lib constants AND a row here together.
NVCLASSIFY="$AIROOTFS/usr/local/lib/ii/nvidia-classify.sh"
if [[ ! -f "$NVCLASSIFY" ]]; then
  _v_fail "nvidia-classify.sh missing from airootfs — HW-01 classifier untestable"
else
  # id<TAB>expected — boundary-dense across Kepler→Maxwell (0x1300) and
  # Pascal/Volta→Turing (0x1E00). Hex forms mixed (0x / bare / upper) on purpose.
  _nv_table='
0x1180	nouveau
0x12ba	nouveau
0x12FF	nouveau
0x1300	legacy
0x1380	legacy
0x13c2	legacy
0x1b80	legacy
0x1d81	legacy
0x1DFF	legacy
0x1E00	open
0x1e04	open
0x1f02	open
0x2204	open
0x2684	open
'
  # Run the table inside a clean subshell so sourcing the lib can't leak into
  # validate's own namespace; fail the whole step on the FIRST mismatch and
  # report it (id, got, expected) so a boundary regression is unambiguous.
  _nv_report="$(
    # shellcheck disable=SC1090
    source "$NVCLASSIFY" || { echo "SOURCE_FAIL"; exit 0; }
    type ii_nvidia_classify &>/dev/null || { echo "NO_FN"; exit 0; }
    _bad=0 _n=0
    while IFS=$'\t' read -r _id _want; do
      [[ -n "$_id" ]] || continue
      _n=$((_n+1))
      _got="$(ii_nvidia_classify "$_id")"
      if [[ "$_got" != "$_want" ]]; then
        echo "MISMATCH $_id got=$_got want=$_want"
        _bad=$((_bad+1))
      fi
    done <<< "$_nv_table"
    # Also assert the multi-GPU fold precedence: legacy beats open beats nouveau.
    _fold="$(ii_nvidia_fold 0x1180 0x1E00 0x1380)"   # has a legacy → must be legacy
    [[ "$_fold" == legacy ]] || { echo "FOLD_BAD got=$_fold want=legacy"; _bad=$((_bad+1)); }
    _fold2="$(ii_nvidia_fold 0x1180 0x2204)"          # open + nouveau → open
    [[ "$_fold2" == open ]] || { echo "FOLD_BAD2 got=$_fold2 want=open"; _bad=$((_bad+1)); }
    _fold3="$(ii_nvidia_fold 0x1180 0x12ff)"          # all sub-Maxwell → nouveau
    [[ "$_fold3" == nouveau ]] || { echo "FOLD_BAD3 got=$_fold3 want=nouveau"; _bad=$((_bad+1)); }
    echo "TOTAL $_n BAD $_bad"
  )"
  if grep -q 'SOURCE_FAIL' <<<"$_nv_report"; then
    _v_fail "nvidia-classify.sh failed to source — HW-01 classifier broken"
  elif grep -q 'NO_FN' <<<"$_nv_report"; then
    _v_fail "nvidia-classify.sh defines no ii_nvidia_classify — HW-01 classifier missing"
  elif grep -qE 'MISMATCH|FOLD_BAD' <<<"$_nv_report"; then
    while IFS= read -r _line; do
      [[ "$_line" == MISMATCH* || "$_line" == FOLD_BAD* ]] && _v_fail "HW-01 classifier: $_line"
    done <<<"$_nv_report"
  else
    _nv_n="$(sed -n 's/.*TOTAL \([0-9]*\) BAD.*/\1/p' <<<"$_nv_report")"
    _v_ok "nvidia classifier passes ${_nv_n:-?} boundary cases + 3 fold-precedence cases (HW-01)"
  fi
fi

# ii-post-install must actually consult the shared classifier (not re-inline a
# divergent copy as the primary path) — guards against the extraction silently
# regressing back to an untested inline loop.
IIPI="$AIROOTFS/usr/local/bin/ii-post-install"
if [[ -f "$IIPI" ]]; then
  if grep -q 'ii_nvidia_fold\|ii_nvidia_classify' "$IIPI" \
     && grep -q 'nvidia-classify.sh' "$IIPI"; then
    _v_ok "ii-post-install sources + uses the pure nvidia classifier (HW-01)"
  else
    _v_fail "ii-post-install does not use the shared nvidia classifier — HW-01 extraction regressed"
  fi
fi

step "host-side pipeline scripts syntax (IMMUNE-02)"
# The check above only parses the *staged* airootfs runtime scripts. The
# host-side pipeline that drives the UNATTENDED release — prebuild, mkiso,
# publish-sf, smoke, vm, update, nspawn, and every prepare.d/* fragment — was
# never syntax-checked, so a typo could survive review and break a cron release
# only at run time. These exist statically (no build needed), so bash -n them
# straight from the source tree. prepare.d/* are *sourced* fragments (no
# shebang by design — see "Conventions"); we only assert they parse.
_host_n=0
shopt -s nullglob
for _hs in "$SCRIPTS"/*.sh "$SCRIPTS"/prepare.d/*.sh; do
  _host_n=$((_host_n+1))
  _hrel="${_hs#"$ROOT"/}"
  bash -n "$_hs" 2>/dev/null \
    && _v_ok "$_hrel" \
    || _v_fail "$_hrel syntax error"
done
shopt -u nullglob
(( _host_n > 0 )) \
  && _v_ok "$_host_n host-side script(s) syntax-checked" \
  || _v_fail "no host-side scripts/*.sh found — SCRIPTS path wrong?"

step "host pacman sync-db guard (BUILD-06)"
# 40-packages classifies every name official-vs-AUR with `pacman -Si` against the
# HOST sync db; an empty/stale db (common on bare local builds, not docked/CI)
# silently misroutes EVERY official package to the AUR/prebuild path. The step
# must assert a populated, recent sync db BEFORE any classification and `die`
# loudly if absent. Guard the guard: it must (a) define & invoke the assertion
# before the first `pacman -Si`, and (b) point the maintainer at `pacman -Sy`.
PKGSTEP="$SCRIPTS/prepare.d/40-packages.sh"
if [[ ! -f "$PKGSTEP" ]]; then
  _v_fail "40-packages.sh missing — BUILD-06 sync-db guard can't be verified"
else
  _b06_code="$(grep -vE '^[[:space:]]*#' "$PKGSTEP")"
  # (a) the assertion is defined and actually invoked.
  if grep -q '_assert_sync_db()' <<<"$_b06_code" \
     && grep -qE '^[[:space:]]*_assert_sync_db[[:space:]]*$' <<<"$_b06_code"; then
    _v_ok "40-packages defines and invokes _assert_sync_db (BUILD-06)"
  else
    _v_fail "40-packages does not invoke _assert_sync_db — official-vs-AUR classification has no sync-db precondition (BUILD-06)"
  fi
  # (b) the guard runs BEFORE the first `pacman -Si` classification call.
  _b06_assert_ln="$(grep -nE '^[[:space:]]*_assert_sync_db[[:space:]]*$' <<<"$_b06_code" | head -1 | cut -d: -f1)"
  _b06_si_ln="$(grep -nE 'pacman -Si ' <<<"$_b06_code" | head -1 | cut -d: -f1)"
  if [[ -n "$_b06_assert_ln" && -n "$_b06_si_ln" ]] && (( _b06_assert_ln < _b06_si_ln )); then
    _v_ok "sync-db assertion precedes the first 'pacman -Si' classification (BUILD-06)"
  else
    _v_fail "sync-db assertion does not precede 'pacman -Si' classification — packages could be misrouted before the guard runs (BUILD-06)"
  fi
  # (c) the failure path points the maintainer at the remedy (`pacman -Sy`) and dies.
  if grep -q 'pacman -Sy' <<<"$_b06_code" && grep -q 'die ' <<<"$_b06_code"; then
    _v_ok "sync-db guard fails loudly via die() and names 'pacman -Sy' as the remedy (BUILD-06)"
  else
    _v_fail "sync-db guard does not die() with a 'pacman -Sy' remedy — failure would be silent or unhelpful (BUILD-06)"
  fi
fi

step "additive/reversibility lint"
# Pillar 6 (the structural checks): skel-upstream precondition + skel-shadow
# collision, packages/optional/*.list validity (no double-bake), pack
# post-add/post-remove hook hygiene (bash -n + mutator inverse symmetry,
# IMMUNE-03), and the PII guard. '|| true' so an unexpected non-zero can't abort
# before the summary (the FAIL tally, not lint_additive's return code, is what
# gates the build).
lint_additive || true

step "docs drift guard (DOC-01)"
# Non-fatal (WARN) sentinels: the doc-drift sweep (DOC-01) corrected two stale
# claims that had crept into four+ docs — a fixed "~55 checks" validate count
# (this script now has ~150) and "phases 4–5 … pending" (the builder container,
# just docked, and release CI all shipped). Warn — never fail — if either string
# reappears, so a future edit re-introducing the drift is surfaced loudly without
# blocking the build. Operates on the tracked source docs, not build/.
_dd_docs=("$ROOT/CLAUDE.md" "$ROOT/README.md" "$ROOT/docs/BLUEPRINT.md" "$ROOT/docs/GUIDE.md" "$ROOT/distro.toml")
_dd_hits=0
for _dd in "${_dd_docs[@]}"; do
  [[ -f "$_dd" ]] || continue
  if grep -qiE '~?55[ -](check|assertion)' "$_dd"; then
    _v_warn "$(basename "$_dd"): stale '~55 checks' validate count — update to the real count (DOC-01/DD-03)"
    _dd_hits=$((_dd_hits+1))
  fi
  if grep -qiE 'phases?[ ]*4[–-]?5?.*(pending|not wired)|phase 4 — not wired|phases 4–5.*pending' "$_dd"; then
    _v_warn "$(basename "$_dd"): stale 'phases 4–5 … pending/not wired' claim — phases 4–5 shipped (DOC-01/DD-01)"
    _dd_hits=$((_dd_hits+1))
  fi
done
(( _dd_hits == 0 )) && _v_ok "no '~55 checks' / 'phases 4–5 … pending' drift sentinels in docs (DOC-01)"

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
