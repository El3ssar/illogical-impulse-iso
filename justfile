# justfile — the only entry point for the Illogical Impulse ISO pipeline.
# Identity + knobs live in distro.toml; logic lives in scripts/.

set shell := ["bash", "-euo", "pipefail", "-c"]

# list recipes
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

# remove build/
clean:
    ./scripts/clean.sh

# remove build/ + out/ + the mkarchiso workdir
nuke:
    ./scripts/clean.sh --hard

# regenerate Calamares branding PNGs from overlay/assets (commit the result)
assets:
    ./tools/gen-assets.sh
