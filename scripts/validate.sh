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
#   • ii-post-install seeds first_run.txt (reversibly) to suppress upstream's
#     welcome so ours shows instead.
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
    && _v_ok "ii-post-install seeds first_run.txt (upstream welcome suppressed; ours shows)" \
    || _v_fail "ii-post-install does not seed first_run.txt — upstream welcome will still fire"
  grep -q 'first-run-welcome' "$POST_F" \
    && _v_ok "first_run.txt seed is ledger-recorded (revert-all restores the upstream welcome)" \
    || _v_warn "first_run.txt seed not recorded in the ledger — revert-all couldn't undo it"
fi

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

step "dev-tooling hygiene"
# `just nspawn` (#31) caches a root-owned, multi-hundred-MB base rootfs under
# .nspawn-cache/ — committing it is the bug-class this guards. Static, repo-level.
if grep -qxF '.nspawn-cache/' "$ROOT/.gitignore" 2>/dev/null; then
  _v_ok ".nspawn-cache/ is git-ignored (just nspawn base stays out of git)"
else
  _v_fail ".nspawn-cache/ not in .gitignore — the just nspawn base rootfs could be committed"
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
