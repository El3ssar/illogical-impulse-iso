# shellcheck shell=bash disable=SC2154
# 30-skel — build the skel layer cake:
#
#   /etc/skel-upstream  = upstream dots, synced verbatim          → liveuser
#   /etc/skel           = skel-upstream + overlay/skel-distro
#                         + overlay/skel-distro.fetch (pinned vendoring)
#                         (+ profiles/$PROFILE/skel last)         → installed user
#   /etc/skel-live      = overlay/skel-live                       → liveuser only
#
# Also stages upstream sdata (uv requirements consumed by ii-build-wheelhouse
# and ii-ensure-venv) under /usr/share/illogical-impulse/sdata.

SKEL_UP="$BUILD/airootfs/etc/skel-upstream"
SKEL="$BUILD/airootfs/etc/skel"
SRC="$DOTS/dots"

# _skel_fetch_guard <dest> <list> — reject upstream-owned (rsync --delete /
# install_dir__sync) skel destinations. A pinned tree landing on one of these
# would be wiped by upstream's own updater on `iictl update`, so a fetch line
# targeting it is a hard build error (PROPOSAL.md §3 seam table, row 4). This is
# a fast-fail prefix guard; the exhaustive build/airootfs collision diff lives
# in tools/lint-additive.sh (issue #8).
_skel_fetch_guard() {
  local dest="$1" list="$2" deny
  local denylist=(
    .config/quickshell .config/matugen
    .config/fish/config.fish .config/fish/functions
    .config/zshrc.d .config/hypr/hyprland .config/fontconfig
    .config/starship.toml .config/hypr/hyprlock.conf
  )
  dest="${dest#./}"; dest="${dest%/}"
  for deny in "${denylist[@]}"; do
    if [[ "$dest" == "$deny" || "$dest" == "$deny"/* ]]; then
      die "skel fetch dest '$dest' is an upstream-owned (rsync --delete) path — wiped on 'iictl update'; use a distro-owned/unowned path ($list)"
    fi
  done
}

# _skel_fetch <list-file> <skel-root> — vendor pinned '<dest> <git-url> <rev>'
# lines from <list-file> into <skel-root>/<dest>, cached under .fetch-cache/ by
# url+rev so a re-run never re-clones. Shared by the distro-level
# overlay/skel-distro.fetch and the per-profile profiles/<name>/fetch.list so
# the two paths cannot drift. Comment (#) and blank lines are skipped.
_skel_fetch() {
  local list="$1" root="$2" dest url rev key _ftmp
  local cache="$ROOT/.fetch-cache"
  install -d "$cache"
  while read -r dest url rev; do
    [[ -z "$dest" || "$dest" == \#* ]] && continue
    [[ -n "${rev:-}" ]] || die "fetch list line needs: <dest> <git-url> <rev> ($list)"
    _skel_fetch_guard "$dest" "$list"
    key="$cache/$(basename "${url%.git}")-${rev:0:12}"
    if [[ ! -d "$key" ]]; then
      info "fetch $url @ ${rev:0:12}"
      _ftmp="$(mktemp -d)"
      git clone --quiet "$url" "$_ftmp/r"                || die "clone failed: $url"
      git -C "$_ftmp/r" checkout --quiet --detach "$rev" || die "rev $rev not found in $url"
      rm -rf "$_ftmp/r/.git"
      mv "$_ftmp/r" "$key"; rm -rf "$_ftmp"
    fi
    install -d "$root/$dest"
    rsync -a "$key/" "$root/$dest/"
    info "$dest ← $(basename "$url") @ ${rev:0:12}"
  done < "$list"
}

step "sync upstream dots → /etc/skel-upstream"
( cd "$DOTS" && git submodule update --init --recursive --quiet ) \
  || die "submodule init failed in $DOTS"
install -d "$SKEL_UP/.config" "$SKEL_UP/.local/share" "$SKEL_UP/.local/state" "$SKEL_UP/.local/bin"

# Most of .config syncs 1:1; the four dirs below need special rsync flags.
while IFS= read -r entry; do
  name="$(basename "$entry")"
  case "$name" in quickshell|fish|hypr|fontconfig) continue ;; esac
  if [[ -d "$entry" ]]; then
    install -d "$SKEL_UP/.config/$name"
    rsync -a --delete "$entry/" "$SKEL_UP/.config/$name/"
  else
    install -Dm 0644 "$entry" "$SKEL_UP/.config/$name"
  fi
done < <(find "$SRC/.config" -mindepth 1 -maxdepth 1)

install -d "$SKEL_UP/.config/quickshell" "$SKEL_UP/.config/fish" "$SKEL_UP/.config/fontconfig" \
           "$SKEL_UP/.config/hypr/hyprland" "$SKEL_UP/.config/hypr/custom/scripts"
rsync -a --delete                  "$SRC/.config/quickshell/"    "$SKEL_UP/.config/quickshell/"
rsync -a --delete --exclude=conf.d "$SRC/.config/fish/"          "$SKEL_UP/.config/fish/"
rsync -a --delete                  "$SRC/.config/fontconfig/"    "$SKEL_UP/.config/fontconfig/"
rsync -a --delete                  "$SRC/.config/hypr/hyprland/" "$SKEL_UP/.config/hypr/hyprland/"

for f in hyprlock.conf hyprland.lua hypridle.conf; do
  [[ -f "$SRC/.config/hypr/$f" ]] && install -Dm 0644 "$SRC/.config/hypr/$f" "$SKEL_UP/.config/hypr/$f"
done
[[ -d "$SRC/.config/hypr/hyprlock" ]] \
  && rsync -a --delete "$SRC/.config/hypr/hyprlock/" "$SKEL_UP/.config/hypr/hyprlock/"

[[ -d "$SRC/.local/share/konsole" ]] \
  && { install -d "$SKEL_UP/.local/share/konsole"
       rsync -a "$SRC/.local/share/konsole/" "$SKEL_UP/.local/share/konsole/"; }
[[ -f "$SRC/.local/share/icons/illogical-impulse.svg" ]] \
  && install -Dm 0644 "$SRC/.local/share/icons/illogical-impulse.svg" \
                      "$SKEL_UP/.local/share/icons/illogical-impulse.svg"

for sub in fcitx5 swaylock; do
  [[ -d "$DOTS/dots-extra/$sub" ]] \
    && { install -d "$SKEL_UP/.config/$sub"
         rsync -a "$DOTS/dots-extra/$sub/" "$SKEL_UP/.config/$sub/"; }
done

find "$SKEL_UP/.config" -type f \( -name '*.sh' -o -name '*.fish' -o -name '*.zsh' -o -name '*.bash' \) \
  -exec chmod 0755 {} + 2>/dev/null || true

[[ -d "$SKEL_UP/.config/quickshell/ii" ]] || die "skel-upstream missing quickshell/ii"
(( $(find "$SKEL_UP" -type f | wc -l) >= 100 )) || die "skel-upstream too sparse"
ok "skel-upstream populated"

step "google-sans-flex font (fetched if absent upstream)"
font_dir="$SKEL_UP/.local/share/fonts/illogical-impulse-google-sans-flex"
if [[ ! -d "$font_dir" ]] || ! find "$font_dir" -name '*.[ot]tf' -print -quit | grep -q .; then
  _font_tmp="$(mktemp -d)"
  if git clone --depth=1 https://github.com/end-4/google-sans-flex "$_font_tmp/g" 2>/dev/null; then
    ( cd "$_font_tmp/g" && git submodule update --init --recursive --quiet 2>/dev/null || true )
    install -d "$font_dir"; rsync -a "$_font_tmp/g/" "$font_dir/"
    ok "fetched"
  else
    warn "font clone failed — upstream setup will fetch it at runtime"
  fi
  rm -rf "$_font_tmp"
else
  ok "already present"
fi

step "stage upstream sdata"
install -d "$BUILD/airootfs/usr/share/illogical-impulse"
rsync -a --delete "$DOTS/sdata/" "$BUILD/airootfs/usr/share/illogical-impulse/sdata/"
ok "sdata staged"

step "/etc/skel = skel-upstream + skel-distro"
install -d "$SKEL"
rsync -a "$SKEL_UP/" "$SKEL/"
[[ -d "$OVERLAY/skel-distro" ]] && rsync -a "$OVERLAY/skel-distro/" "$SKEL/"
# OOB state defaults (static kitty-theme.conf) must also reach liveuser,
# who is seeded from skel-upstream + skel-live, never from /etc/skel.
[[ -d "$OVERLAY/skel-distro/.local/state" ]] \
  && rsync -a "$OVERLAY/skel-distro/.local/state/" "$SKEL_UP/.local/state/"
ok "/etc/skel built"

# Distro-level pinned vendoring (PROPOSAL.md §4 Pillar 2 / BLUEPRINT.md §8):
# clone pinned trees into /etc/skel AFTER the skel-distro overlay and BEFORE the
# profile layer, preserving the cake order
# skel-upstream → skel-distro → skel-distro.fetch → profile (a profile
# fetch.list line to the same dest still wins). Ships comment-only → no-op.
if [[ -f "$OVERLAY/skel-distro.fetch" ]]; then
  step "skel-distro.fetch → /etc/skel (distro pinned vendoring)"
  _skel_fetch "$OVERLAY/skel-distro.fetch" "$SKEL"
  ok "skel-distro.fetch layered"
fi

if [[ -n "$PROFILE" ]]; then
  step "profile '$PROFILE' skel layer"
  [[ -d "$PROFILES/$PROFILE/skel" ]] && rsync -a "$PROFILES/$PROFILE/skel/" "$SKEL/"
  FETCH="$PROFILES/$PROFILE/fetch.list"
  [[ -f "$FETCH" ]] && _skel_fetch "$FETCH" "$SKEL"
  ok "profile layered"
fi

step "overlay/skel-live → /etc/skel-live"
install -d "$BUILD/airootfs/etc/skel-live"
[[ -d "$OVERLAY/skel-live" ]] && rsync -a "$OVERLAY/skel-live/" "$BUILD/airootfs/etc/skel-live/"
ok "skel-live staged"
