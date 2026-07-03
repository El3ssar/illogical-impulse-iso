# justfile — the only entry point for the Illogical Impulse ISO pipeline.
# Identity + knobs live in distro.toml; logic lives in scripts/.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list recipes
[private]
default:
    @just --list --unsorted

# one-time: init/refresh git submodules
setup:
    git submodule update --init --recursive

# assemble build/ (optionally with a profile: just prepare myprofile)
prepare profile="":
    PROFILE="{{profile}}" ./scripts/prepare.sh

# build AUR/local packages into the local [ii-extra] repo cache
prebuild:
    ./scripts/prebuild.sh

# full pipeline → out/*.iso (profile optional: just build myprofile)
build profile="": (prepare profile) prebuild
    ./scripts/mkiso.sh

# static audit of build/
validate:
    ./scripts/validate.sh

# bump the dots submodule pin (`just update --check` for a policy dry-run)
update *args:
    ./scripts/update.sh {{args}}

# boot the newest ISO in QEMU (--disk to test a full install)
vm *args:
    ./scripts/vm.sh {{args}}

# headless smoke of the newest ISO (used by the release CI).
#   just smoke               live-ISO boot probe only (scripts/smoke.sh — release CI)
#   just smoke --full        boot probe + post-boot battery (doctor · qs-load · pack · revert-all)
#   just smoke --build       bake a fresh ISO first, then the boot probe
#   just smoke --build --full bake fresh, then the whole functional battery (merge gate)
#   just smoke --installed   unattended install → boot the installed disk (TEST-01)
# `--installed` routes to the heavier install smoke; everything else (incl. --full
# and --build) is the live smoke, which stays boot-only when given no flags — so
# the release CI's plain `just smoke` invocation is byte-for-byte unchanged.
smoke *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ " {{args}} " == *" --installed "* ]]; then
        exec ./scripts/install-smoke.sh {{args}}
    else
        exec ./scripts/smoke.sh {{args}}
    fi

# live-preview a standalone Quickshell app (no build); `just preview` lists them
preview app="":
    ./scripts/preview.sh {{app}}

# throwaway systemd-nspawn container to test CLI/iictl behaviour (no ISO bake)
# quote(args) forwards the whole command as ONE shell-safe arg, so `;`/`&&`/`|`
# in it run in the container, not the host recipe shell.
# `just nspawn` = root shell · `just nspawn '<cmd>'` = one-shot · `--clean` drops the cache
nspawn *args:
    ./scripts/nspawn.sh {{ quote(args) }}

# Iron Law round-trip: seed the ledger via the real mutators + pack engine in a
# throwaway nspawn box, run `iictl revert-all`, assert vanilla returns (needs root)
test-revert:
    ./tests/revert-roundtrip.sh

# remove build/
clean:
    ./scripts/clean.sh

# remove build/ + out/ + the mkarchiso workdir
nuke:
    ./scripts/clean.sh --hard

# regenerate Calamares branding PNGs from overlay/assets (commit the result)
assets:
    ./tools/gen-assets.sh

# build the pinned builder container image
image:
    docker build -t ii-builder:latest -f containers/builder.Dockerfile containers

# reproducible build inside the container (any host with docker) → out/*.iso
# AUR cache: `ii-extra-cache` docker volume, or a host dir via II_CACHE_DIR
# (the release CI binds a cached directory there).
docked profile="": image
    docker run --rm --privileged \
      -e HOST_UID="$(id -u)" \
      -v "{{justfile_directory()}}:/work" \
      -v "${II_CACHE_DIR:-ii-extra-cache}:/var/cache/ii-extra-repo" \
      -w /work ii-builder:latest \
      bash -c 'usermod -u "$HOST_UID" builder 2>/dev/null; \
               chown builder /var/cache/ii-extra-repo && \
               su builder -c "just prepare {{profile}} && just validate && just prebuild" && \
               ./scripts/mkiso.sh'
