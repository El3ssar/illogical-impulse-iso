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
# nvidia-classify.sh — pure install-time PCI-id → driver-variant classifier
# (HW-01). Sourced by ii-post-install; stateless function lib, safe to leave on
# disk (no side effects), unit-tested by validate.sh's HW-01 table.
install -Dm 0644 "$SCRIPTS/runtime-lib/nvidia-classify.sh" \
                 "$BUILD/airootfs/usr/local/lib/ii/nvidia-classify.sh"
# iictl framework: shared header + ledger + mutator (sourced libs, 0644) and the
# iictl.d/ drop-in subcommands (executable, 0755). These ride the survive-path —
# ii-verify purges /usr/local/lib/ii by named file, keeping iictl.d/ + ledger.sh
# + mutator.sh so the installed system's iictl plugin layer + `iictl revert-all`
# work (PROPOSAL §4 Pillar 0/3/4 + shared mutator library).
install -Dm 0644 "$SCRIPTS/runtime-lib/iictl-common.sh" \
                 "$BUILD/airootfs/usr/local/lib/ii/iictl-common.sh"
install -Dm 0644 "$SCRIPTS/runtime-lib/ledger.sh" \
                 "$BUILD/airootfs/usr/local/lib/ii/ledger.sh"
install -Dm 0644 "$SCRIPTS/runtime-lib/mutator.sh" \
                 "$BUILD/airootfs/usr/local/lib/ii/mutator.sh"
install -d "$BUILD/airootfs/usr/local/lib/ii/iictl.d"
for _plugin in "$SCRIPTS/runtime-lib/iictl.d/"*; do
  [[ -f "$_plugin" ]] || continue   # skips the dir if it holds only the dotfile .keep
  install -Dm 0755 "$_plugin" \
    "$BUILD/airootfs/usr/local/lib/ii/iictl.d/$(basename "$_plugin")"
done
install -Dm 0755 "$SCRIPTS/chroot.sh" "$BUILD/airootfs/root/customize_airootfs.sh"
# Referenced from profiledef file_permissions; populated by 40-packages.
: > "$BUILD/airootfs/root/aur-packages.txt"
ok "$(ls "$SCRIPTS/runtime" | wc -l) runtime scripts + chroot hook staged"
ok "iictl framework staged ($(find "$BUILD/airootfs/usr/local/lib/ii/iictl.d" -maxdepth 1 -type f | wc -l) iictl.d/ plugin(s) + header + ledger + mutator)"
