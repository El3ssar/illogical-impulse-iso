# shellcheck shell=bash disable=SC2154
# 70-assets — generated identity files + default wallpaper.
# os-release and the release stamp are generated (not static) so identity
# lives in distro.toml and the build is self-describing.

DOTS_COMMIT="$(git -C "$DOTS" rev-parse --short HEAD)"

step "generate /etc/os-release"
cat > "$BUILD/airootfs/etc/os-release" <<OSR
NAME="$DISTRO_NAME"
PRETTY_NAME="$(tget distro.pretty_name)"
ID=$DISTRO_ID
ID_LIKE=arch
VERSION_ID=$ISO_VERSION
BUILD_ID=$ISO_VERSION
ANSI_COLOR="$(tget distro.ansi_color)"
LOGO=$DISTRO_ID
HOME_URL="$(tget distro.home_url)"
DOCUMENTATION_URL="$(tget distro.docs_url)"
SUPPORT_URL="$(tget distro.bug_url)"
BUG_REPORT_URL="$(tget distro.bug_url)"
OSR
ok "os-release ($ISO_VERSION)"

step "release stamp → /etc/$DISTRO_ID/release"
install -d "$BUILD/airootfs/etc/$DISTRO_ID"
# DOTS_COMMIT is the stable PIN: `iictl update` (default channel) checks out
# exactly this commit before driving upstream's ./setup, instead of HEAD. It is
# the submodule HEAD at build time, so a `just update` submodule bump
# automatically advances the next build's pin — validate.sh asserts the two
# agree (anti-rot, #27). CHANNEL is the distro-owned channel marker the installed
# system flips with `iictl update --channel edge|stable`; it lives here (never an
# upstream path) so a channel switch is a single reversible line.
cat > "$BUILD/airootfs/etc/$DISTRO_ID/release" <<REL
ISO_VERSION=$ISO_VERSION
DOTS_COMMIT=$DOTS_COMMIT
CHANNEL=stable
BUILD_DATE=$(date -u +%FT%TZ)
PROFILE=${PROFILE:-none}
REL
ok "dots @ $DOTS_COMMIT (channel=stable)"

step "default wallpaper → skel + skel-upstream"
if [[ -f "$OVERLAY/assets/default-wallpaper.png" ]]; then
  for s in skel skel-upstream; do
    install -d "$BUILD/airootfs/etc/$s/.config/quickshell/ii/assets/images" \
               "$BUILD/airootfs/etc/$s/Pictures/Wallpapers"
    install -m 0644 "$OVERLAY/assets/default-wallpaper.png" \
      "$BUILD/airootfs/etc/$s/.config/quickshell/ii/assets/images/default_wallpaper.png"
    install -m 0644 "$OVERLAY/assets/default-wallpaper.png" \
      "$BUILD/airootfs/etc/$s/Pictures/Wallpapers/illogical-impulse-default.png"
  done
  ok "installed"
else
  warn "overlay/assets/default-wallpaper.png missing"
fi
