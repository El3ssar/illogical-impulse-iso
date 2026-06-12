# shellcheck shell=bash disable=SC2154
# 30-skel — build the skel layer cake:
#
#   /etc/skel-upstream  = upstream dots, synced verbatim          → liveuser
#   /etc/skel           = skel-upstream + overlay/skel-distro
#                         (+ profiles/$PROFILE/skel last)         → installed user
#   /etc/skel-live      = overlay/skel-live                       → liveuser only
#
# Also stages upstream sdata (uv requirements consumed by ii-build-wheelhouse
# and ii-ensure-venv) under /usr/share/illogical-impulse/sdata.

SKEL_UP="$BUILD/airootfs/etc/skel-upstream"
SKEL="$BUILD/airootfs/etc/skel"
SRC="$DOTS/dots"

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

if [[ -n "$PROFILE" ]]; then
  step "profile '$PROFILE' skel layer"
  [[ -d "$PROFILES/$PROFILE/skel" ]] && rsync -a "$PROFILES/$PROFILE/skel/" "$SKEL/"
  FETCH="$PROFILES/$PROFILE/fetch.list"
  if [[ -f "$FETCH" ]]; then
    FETCH_CACHE="$ROOT/.fetch-cache"
    install -d "$FETCH_CACHE"
    while read -r dest url rev; do
      [[ -z "$dest" || "$dest" == \#* ]] && continue
      [[ -n "${rev:-}" ]] || die "fetch.list line needs: <dest> <git-url> <rev>"
      key="$FETCH_CACHE/$(basename "${url%.git}")-${rev:0:12}"
      if [[ ! -d "$key" ]]; then
        info "fetch $url @ ${rev:0:12}"
        _ftmp="$(mktemp -d)"
        git clone --quiet "$url" "$_ftmp/r"           || die "clone failed: $url"
        git -C "$_ftmp/r" checkout --quiet --detach "$rev" || die "rev $rev not found in $url"
        rm -rf "$_ftmp/r/.git"
        mv "$_ftmp/r" "$key"; rm -rf "$_ftmp"
      fi
      install -d "$SKEL/$dest"
      rsync -a "$key/" "$SKEL/$dest/"
      info "$dest ← $(basename "$url") @ ${rev:0:12}"
    done < "$FETCH"
  fi
  ok "profile layered"
fi

step "overlay/skel-live → /etc/skel-live"
install -d "$BUILD/airootfs/etc/skel-live"
[[ -d "$OVERLAY/skel-live" ]] && rsync -a "$OVERLAY/skel-live/" "$BUILD/airootfs/etc/skel-live/"
ok "skel-live staged"
