# shellcheck shell=bash disable=SC2154
# 20-airootfs — layer overlay/airootfs onto the baseline and stage the
# runtime scripts + the mkarchiso chroot customization hook.

step "overlay/airootfs → build/airootfs"
rsync -a "$OVERLAY/airootfs/" "$BUILD/airootfs/"
ok "airootfs layered"

step "stage runtime scripts + chroot hook"
install -d "$BUILD/airootfs/usr/local/bin" \
           "$BUILD/airootfs/usr/local/lib/ii" \
           "$BUILD/airootfs/root"
install -Dm 0755 "$SCRIPTS/runtime/"* "$BUILD/airootfs/usr/local/bin/"
install -Dm 0644 "$SCRIPTS/runtime-lib/session-offline.sh" \
                 "$BUILD/airootfs/usr/local/lib/ii/session-offline.sh"
install -Dm 0755 "$SCRIPTS/chroot.sh" "$BUILD/airootfs/root/customize_airootfs.sh"
# Referenced from profiledef file_permissions; populated by 40-packages.
: > "$BUILD/airootfs/root/aur-packages.txt"
ok "$(ls "$SCRIPTS/runtime" | wc -l) runtime scripts + chroot hook staged"
