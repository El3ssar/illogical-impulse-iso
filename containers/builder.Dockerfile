# Builder image for the Illogical Impulse ISO — the canonical, reproducible
# build environment. `just docked` runs the full pipeline inside it; the
# release CI (phase 5) uses the same image, so local and automated builds
# can't drift.
#
# Build:  just image        (docker build -t ii-builder:latest containers)
# Use:    just docked       (full pipeline → out/*.iso)

FROM archlinux:base-devel

RUN pacman -Syu --noconfirm \
      archiso just rsync python git curl \
      xorriso squashfs-tools dosfstools e2fsprogs erofs-utils mtools \
      libisoburn \
    && pacman -Scc --noconfirm

# makepkg refuses root: prebuild runs as `builder` (uid remapped to the
# host user at runtime so build/ stays host-owned — see iron rule #2).
RUN useradd -m -u 1000 builder \
    && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder \
    && chmod 440 /etc/sudoers.d/builder \
    && git config --system --add safe.directory '*'

WORKDIR /work
