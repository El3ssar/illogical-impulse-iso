#!/usr/bin/env bash
# Regenerate the committed brand assets from overlay/assets/branding/wordmark.svg.
# Not called by the build pipeline — run manually when you change the wordmark
# or default wallpaper, review the diff, commit the PNGs.
#
# Outputs:
#   overlay/calamares/branding/illogical-impulse/logo.png         (512x512)
#   overlay/calamares/branding/illogical-impulse/welcome.png      (1920x1080)
#   overlay/airootfs/usr/share/pixmaps/illogical-impulse.png      (512x512, for os-release LOGO=)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORDMARK="$ROOT/overlay/assets/branding/wordmark.svg"
LOGO_SVG="$ROOT/overlay/assets/branding/logo.svg"
WALL="$ROOT/overlay/assets/default-wallpaper.png"
OUT_LOGO="$ROOT/overlay/calamares/branding/illogical-impulse/logo.png"
OUT_WELCOME="$ROOT/overlay/calamares/branding/illogical-impulse/welcome.png"
OUT_PIXMAP="$ROOT/overlay/airootfs/usr/share/pixmaps/illogical-impulse.png"

PAL_BASE="#1e1e2e" PAL_CRUST="#11111b" PAL_TEXT="#cdd6f4"
PAL_MAUVE="#cba6f7" PAL_TEAL="#94e2d5"

command -v magick >/dev/null \
  || { echo "ERROR: imagemagick missing (pacman -S imagemagick)" >&2; exit 1; }

HAS_WORDMARK=0; [[ -f "$WORDMARK" ]] && HAS_WORDMARK=1
HAS_WALL=0;     [[ -f "$WALL"     ]] && HAS_WALL=1
(( HAS_WORDMARK || HAS_WALL )) \
  || { echo "ERROR: need overlay/assets/branding/wordmark.svg or default-wallpaper.png" >&2; exit 1; }
(( HAS_WORDMARK )) && ! command -v rsvg-convert >/dev/null \
  && { echo "ERROR: rsvg-convert missing (pacman -S librsvg)" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

bg() {  # Catppuccin radial bg of WxH → $1
  local out=$1 w=$2 h=$3
  magick -size "${w}x${h}" radial-gradient:"${PAL_BASE}-${PAL_CRUST}" \
    \( -size "${w}x${h}" radial-gradient:"#cba6f73c-#00000000" \) \
    -compose blend -define compose:args=50 -composite \
    -depth 8 "$out"
}

# ── 1. logo.png — the distro icon (vectorized favicon), wordmark fallback ──
echo ">> logo.png"
if [[ -f "$LOGO_SVG" ]]; then
  rsvg-convert -w 512 -h 512 "$LOGO_SVG" -o "$work/logo.png"
elif (( HAS_WORDMARK )); then
  rsvg-convert -w 6885 -h 1824 "$WORDMARK" -o "$work/wm.png"
  magick "$work/wm.png" -crop 1820x1820+0+0 +repage -resize 512x512 -depth 8 "$work/logo.png"
elif (( HAS_WALL )); then
  magick "$WALL" -resize 512x512^ -gravity center -extent 512x512 "$work/logo.png"
else
  magick -size 512x512 xc:"$PAL_BASE" "$work/logo.png"
fi
install -Dm 0644 "$work/logo.png" "$OUT_LOGO"   ; echo "   $OUT_LOGO"
install -Dm 0644 "$work/logo.png" "$OUT_PIXMAP" ; echo "   $OUT_PIXMAP"

# ── 1b. logo.txt — HAND-CRAFTED, not generated ─────────────────────────────
# overlay/airootfs/etc/illogical-impulse/logo.txt is hand-drawn ASCII art
# (48x24, $1=disc / $2=artwork fastfetch color tokens). Do NOT generate or overwrite
# it here — edit it by hand and keep the token scheme.

# ── 2. welcome.png — 1920x1080 Calamares hero ─────────────────────────────
echo ">> welcome.png"
if (( HAS_WALL )); then
  magick "$WALL" -resize 1920x1080^ -gravity center -extent 1920x1080 \
    \( -size 1920x1080 gradient:"#11111b80-#1e1e2e40" \) \
    -compose over -composite -depth 8 "$work/bg.png"
else
  bg "$work/bg.png" 1920 1080
fi

if (( HAS_WORDMARK )); then
  magick -size 1920x1080 xc:none \
    -fill "$PAL_TEAL"  -draw "circle 1740,140 1740,40"  \
    -fill "$PAL_MAUVE" -draw "circle 180,940 180,840"   \
    -blur 0x55 -channel A -evaluate multiply 0.32 +channel "$work/accents.png"
  rsvg-convert -w 1100 "$WORDMARK" -o "$work/wm-1100.png"
  magick "$work/wm-1100.png" \
    \( +clone -background "$PAL_CRUST" -shadow 50x18+0+12 \) +swap \
    -background none -layers merge +repage "$work/wm-shadow.png"
  magick -size 1100x3 gradient:"${PAL_TEAL}-${PAL_MAUVE}" "$work/rule.png"
  magick -size 1100x90 xc:none -gravity center \
    -font "DejaVu-Sans"     -pointsize 24 -fill "$PAL_TEXT"  \
      -annotate +0-16 "An Arch Linux distribution shaped around end-4's Hyprland rice" \
    -font "DejaVu-Sans"     -pointsize 15 -fill "$PAL_MAUVE" \
      -annotate +0+26 "Wayland  ·  Quickshell  ·  Matugen" \
    "$work/tag.png"
  magick "$work/wm-shadow.png" \
    \( -size 1x28 xc:none \) "$work/rule.png" \
    \( -size 1x24 xc:none \) "$work/tag.png" \
    -background none -gravity center -append "$work/hero.png"
  magick "$work/bg.png" \
    "$work/accents.png" -compose over -composite \
    "$work/hero.png" -gravity center -geometry +0-40 -compose over -composite \
    -depth 8 "$work/welcome.png"
else
  magick "$work/bg.png" \
    -gravity south -fill "$PAL_TEXT"  -font "DejaVu-Sans-Bold" -pointsize 36 \
      -annotate +0+80 "Illogical Impulse" \
    -fill "$PAL_MAUVE" -font "DejaVu-Sans" -pointsize 18 \
      -annotate +0+40 "Install Hyprland the end-4 way" \
    -depth 8 "$work/welcome.png"
fi
install -Dm 0644 "$work/welcome.png" "$OUT_WELCOME" ; echo "   $OUT_WELCOME"

echo
echo "Done. Review with: git diff -- overlay/calamares/branding/ overlay/airootfs/usr/share/pixmaps/"
