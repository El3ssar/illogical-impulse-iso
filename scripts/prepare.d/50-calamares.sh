# shellcheck shell=bash disable=SC2154
# 50-calamares — stage installer config + branding.
#
# No software-selection page: the distro ships batteries included (every
# default is baked into the image; NVIDIA is hardware-detected by
# ii-post-install from the on-ISO stash).

step "overlay/calamares → airootfs/etc/calamares"
install -d "$BUILD/airootfs/etc/calamares"
rsync -a "$OVERLAY/calamares/" "$BUILD/airootfs/etc/calamares/"
ok "Calamares staged"
