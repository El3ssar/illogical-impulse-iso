# Builder image for the Illogical Impulse ISO — the canonical, reproducible
# build environment. `just docked` runs the full pipeline inside it; the
# release CI (phase 5) uses the same image, so local and automated builds
# can't drift.
#
# Build:  just image        (docker build -t ii-builder:latest containers)
# Use:    just docked       (full pipeline → out/*.iso)

FROM archlinux:base-devel

# archiso pin + supported range (BUILD-05).
#
# scripts/chroot.sh is staged as /root/customize_airootfs.sh and run by
# mkarchiso's `_make_customize_airootfs` hook — a mechanism mkarchiso ITSELF
# warns is deprecated ("Support for it will be removed in a future archiso
# version"). The whole keyring/paru/wheelhouse/liveuser-seed/microcode-stash/
# sanity-gate bootstrap rides on that hook. If a host archiso update drops it,
# the ISO still BUILDS but ships broken (no paru, no venv, no microcode, …).
#
# Supported range: archiso >= 75 (releng profile shape this pipeline targets)
# and the hook present (mkarchiso must still run customize_airootfs.sh).
# ARCHISO_PIN below is the exact known-good version this image builds against;
# bump it deliberately after re-confirming the hook survives. The mkiso.sh +
# validate.sh BUILD-05 guard re-checks the *installed* mkarchiso at build time,
# so a drift past this pin (or a manual host bump) fails LOUDLY, not silently.
ARG ARCHISO_PIN=88-1

RUN pacman -Syu --noconfirm \
      "archiso=${ARCHISO_PIN}" just rsync python git curl \
      xorriso squashfs-tools dosfstools e2fsprogs erofs-utils mtools \
      libisoburn \
    && pacman -Scc --noconfirm

# Fail the IMAGE build itself if this archiso no longer runs the deprecated
# customize_airootfs.sh hook — the same assertion mkiso.sh/validate.sh make at
# pipeline time, pulled forward so a stale pin can never bake a broken image.
RUN grep -q 'customize_airootfs.sh' "$(command -v mkarchiso)" \
    || { echo "FATAL: archiso ${ARCHISO_PIN} mkarchiso no longer runs customize_airootfs.sh (BUILD-05)"; exit 1; }

# makepkg refuses root: prebuild runs as `builder` (uid remapped to the
# host user at runtime so build/ stays host-owned — see iron rule #2).
RUN useradd -m -u 1000 builder \
    && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder \
    && chmod 440 /etc/sudoers.d/builder \
    && git config --system --add safe.directory '*'

WORKDIR /work
