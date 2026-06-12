# Illogical Impulse ISO — Maintainer Blueprint

How the build machine works and how to modify it: scripts, pipelines, just
recipes, contracts between stages, and the decision record behind the
architecture. For *using* the distro's knobs (branding, packages, dotfiles)
read [GUIDE.md](GUIDE.md) instead — this document is for people changing
the machine itself.

---

## 1. Decision record (what this is and why)

| Topic | Decision |
|---|---|
| Identity | `illogical-impulse` — end-4's rice as an installable distro; goal is upstream collaboration. Identity strings live ONLY in `distro.toml`. |
| Distribution model | **Batteries included, zero questions.** Every default is baked (`packages/goodies.list`). No install-time software selection — that machinery was built (netinstall + on-ISO repo + bind mounts), hit Calamares integration friction, and was deliberately removed. |
| NVIDIA | The one thing that can't be baked (nvidia-utils blacklists nouveau → breaks non-NVIDIA machines). Hardware auto-detect at install from an on-ISO stash repo; classification by PCI device id (`≥0x1E00` Turing+ → open, `0x1300–0x1DFF` → 580xx legacy, older → nouveau). `supported-gpus.json` no longer exists in any package — do not reintroduce a dependency on it. |
| Installer | Calamares, branded. With selection gone, its remaining job (partitioning/LUKS/users/unpack/bootloader) is exactly what it's best at. A Quickshell-native installer is the long-term dream, not current work. |
| Upstream tracking | Pinned submodule. Bump policy = knobs in `[upstream]` of distro.toml, enforced by `update.sh --check` (the future CI cron calls the same gate). |
| Build env | Native Arch host today; pinned builder container is phase 4. archiso releng baseline comes from the **installed archiso package** (no vendored copy). |
| CI | `validate.yml` runs `just prepare && just validate` per push/PR. Release automation (build + QEMU smoke + publish) is phase 5; ISO hosting target is SourceForge (GitHub caps release assets at 2 GiB). |
| Versioning | ISO version = build date (`YYYY.MM.DD`); release stamp at `/etc/illogical-impulse/release` records dots commit + profile. |

**Phase status:** 1 (pipeline) ✅ · 2 (installer, revised model) ✅ ·
3 (iictl + welcome card; cheatsheet dropped — upstream ships one) ✅ ·
4 (builder container, `just docked`) ✅ · 5 (release CI) ✅

Phase 3 collision contract: the welcome card is a STANDALONE quickshell
config (`/usr/share/illogical-impulse/welcome`, zero imports from
upstream's tree) launched by `iictl welcome --auto` from the skel-distro
`custom/execs.lua` (upstream's sanctioned user-override slot, shipped
empty by them). Sequencing: upstream's welcome app owns the first login
(first_run.txt marker); our card takes the next login, once
(~/.local/state/illogical-impulse/welcome_shown).

---

## 2. Scaffold

```
distro.toml          identity + knobs — the ONLY place identity strings live
justfile             the only entry point; recipes are thin wrappers over scripts/
packages/            declarative payload manifests (see GUIDE §3)
profiles/<name>/     personal layers: skel/, packages.list, fetch.list
overlay/             distro payload: airootfs/, skel-distro/, skel-live/,
                     calamares/, efiboot/, assets/, aur-pkgbuilds/, pacman.conf
scripts/
├── lib/common.sh    shared env — paths, tget(), step/ok/warn/info/die, _wipe
├── lib/toml-get     python3-tomllib reader: toml-get FILE dotted.key
├── prepare.sh       runs prepare.d/NN-*.sh in order (sourced, shared env)
├── prepare.d/       10-releng 20-airootfs 30-skel 40-packages 50-calamares
│                    60-boot 70-assets
├── prebuild.sh      AUR/local PKGBUILDs → /var/cache/ii-extra-repo + staging
├── mkiso.sh         mkarchiso wrapper (self-sudo)
├── validate.sh      static audit (~55 checks)
├── update.sh        submodule bump + --check policy gate
├── vm.sh            QEMU: live / --disk / --installed / --fresh-disk
├── clean.sh         build/ (--hard: + out/ + workdir)
├── chroot.sh        runs INSIDE mkarchiso chroot (customize_airootfs)
├── runtime/         → airootfs /usr/local/bin (live session + Calamares hooks)
└── runtime-lib/     → /usr/local/lib/ii (ii_* chroot-safe helpers)
tools/               manual utilities: gen-assets.sh, resolve-deps.py
upstream/illogical-impulse   the dots — read-only submodule
```

## 3. Iron rules

1. **Identity from distro.toml only** — scripts read it via `tget`;
   greppable hardcoded names are bugs.
2. **mkiso.sh (root) never writes into `build/`** — root-owned droppings
   brick the next user-level prepare wipe. User-level staging belongs in
   prebuild.sh.
3. **One prepare.d step = one concern.** New behavior → new `NN-*.sh`, not
   growth of an existing one. Steps are *sourced* in order and share
   common.sh's env; prefix internal vars to avoid collisions.
4. **`((var++))` is banned** — post-increment of 0 + `set -e` = silent
   death (cost us a build). Use `var=$((var+1))`. Installer-side `set -e`
   scripts carry an ERR trap printing `line $LINENO: $BASH_COMMAND` — keep
   that pattern in new scripts.
5. **Every fixed bug becomes a validate check** (and, if it bit hard, an
   entry in CLAUDE.md §"Historic bugs"). validate.sh is the project's
   immune system: ~55 checks, each encoding a real failure mode.
6. **Flat pacman repos** — db and `.pkg.tar.*` share one directory; pacman
   fetches `$Server/$filename`. Filter `.sig` files out of `repo-add`.
7. Runtime/installed artifacts use the `ii-`/`ii_` prefix.

## 4. Pipeline contracts

`just build [profile]` = `prepare [profile]` → `prebuild` → `mkiso`.

### prepare (user, no root)

Wipes and reassembles `build/` from scratch — it is always safe to delete.
Step contract: each `prepare.d/NN-*.sh` reads repo sources + `$PROFILE`,
writes only under `$BUILD`, and must be idempotent-by-reconstruction (no
step edits another step's output unless documented — 60-boot regenerating
releng's profiledef is the exception).

Step map (current):
- **10-releng** — `/usr/share/archiso/configs/releng` → build/; prunes
  BIOS bootloaders; stages host pacman.conf (with `[ii-extra]`).
- **20-airootfs** — overlay/airootfs + runtime scripts (`/usr/local/bin`),
  runtime-lib (`/usr/local/lib/ii`), chroot.sh → `customize_airootfs.sh`.
- **30-skel** — the layer cake: dots → skel-upstream; +skel-distro →
  /etc/skel; +profile skel & fetch.list (pinned clones, cached in
  `.fetch-cache/`); skel-live; upstream sdata → `/usr/share/illogical-impulse/sdata`;
  google-sans-flex fetch.
- **40-packages** — packages.x86_64 = releng ∪ scraped upstream PKGBUILD
  deps (`tools/resolve-deps.py`) ∪ manifests ∪ profile. Names classified
  against the sync db (`pacman -Si`); AUR names accumulate in
  `.pkg-resolve/aur-prebuild.list`. Writes `/root/nvidia-{official,aur}.txt`
  manifests for the stash. Optional `overlay/aur-pkgbuilds` staged.
- **50-calamares** — installer config + branding, verbatim.
- **60-boot** — efiboot menu; regenerates `profiledef.sh` (identity from
  distro.toml, everything else inherited from releng); declares
  `file_permissions` for every file we add — **dangling entries abort
  mkarchiso**, and the step pre-checks them.
- **70-assets** — *generates* os-release + `/etc/illogical-impulse/release`
  stamp (ISO version, dots commit, profile); installs default wallpaper
  into both skels.

### prebuild (user; sudo only for cache writes)

Per-package cache decision: `*-git` → rebuild unless cached artifact is
younger than `GIT_FRESH_HOURS` (default 6 — retry loops don't recompile
quickshell); local PKGBUILD (`overlay/aur-pkgbuilds/<name>`, **always wins
over AUR**) → compare pkgver-pkgrel; plain AUR → compare RPC version; RPC
unreachable → trust cache. Builds happen under `/var/tmp` (never /tmp —
tmpfs quotas killed an nvidia build), `makepkg` gets one `-C` retry
(transient download resets), the stale-cache wipe happens only AFTER a
successful build, and **all split-package siblings are staged** (one
pkgbase can satisfy several required names). Ends by staging the AUR
nvidia packages into `build/airootfs/usr/share/illogical-impulse/nvidia/`.

### mkiso (self-sudo)

Wipes the workdir, runs `mkarchiso`, keeps the workdir on failure
(`…/airootfs/var/log/customize_airootfs.log` is the black box). Writes
nothing into build/ (rule 2).

### chroot.sh (inside mkarchiso)

Stages, in order: keyring → build deps → paru (fail-soft) → cosmetic AUR
(fail-soft) → **nvidia stash repo** (officials + dep closure via per-package
`pacman -Sw` against a temp conf; AUR variants pre-staged; flat repo-add) →
python wheelhouse → skel +x repair → liveuser seed (skel-upstream +
skel-live) → liveuser venv → services → microcode stash (mkarchiso wipes
/boot after this script) → sanity gate (aborts the ISO if anything
critical is missing) → cleanup.

### Calamares sequence (install time)

`partition → mount → unpackfs → …system modules… → shellprocess@copy-kernel
(ii-prepare-bootloader: universal mkinitcpio, per-kernel presets+fallback,
microcode restore, cmdline incl. LUKS/resume) → bootloader →
shellprocess@finish-boot (ii-finish-systemd-boot: kernel-install entries
for EVERY kernel, EFI fallback binary, cmdline patch, hibernate logind) →
shellprocess@post-install (ii-post-install: user/groups, liveuser removal,
installer purge, greetd template, NVIDIA auto-detect+install, docker wiring,
venv, fail-soft `try` semantics) → shellprocess@verify-install (ii-verify:
final gate + live-helper purge) → umount`.

**The @-instance pitfall:** every `shellprocess@<id>` MUST have an
`instances:` mapping in settings.conf or Calamares silently loads the no-op
`shellprocess.conf`. validate checks this; don't remove the check.

### docked builds (phase 4)

`containers/builder.Dockerfile` is the canonical environment; `just docked`
runs prepare → validate → prebuild (as the `builder` user, uid-remapped to
the host user so build/ stays host-owned — iron rule 2 holds inside docker
too) → mkiso (root), with the AUR cache persisted in the `ii-extra-cache`
docker volume. `--privileged` is required (mkarchiso needs loop devices).
The phase-5 release CI uses this same image.

## 5. The justfile

Recipes are deliberately one-liners delegating to scripts — CI calls the
same surface, so behavior can't fork between local and automated builds.
Adding a recipe: script first (sourcing common.sh), recipe second, README
table third. Current surface: `setup prepare prebuild build validate
update vm clean nuke assets`.

## 6. Validation & testing

- `just validate` — static, no root, fast. Structure: profiledef →
  packages.x86_64 criticals → airootfs structure → identity → Calamares
  (branding, instance mapping, unpackfs sourcefs, bootloader) → batteries
  spot-check + nvidia manifests → mkinitcpio hooks → repo conf → script
  syntax (`bash -n` everything).
- `just vm [--disk|--installed|--fresh-disk]` — the manual gate today, the
  CI smoke test of phase 5.
- `.github/workflows/validate.yml` — prepare+validate in an
  `archlinux:base-devel` container on push/PR.

## 7. Update & release flow

`just update` fast-forwards the dots submodule (dirty-tree guarded);
`just update --check` evaluates the bump policy (`min_days_between_releases`,
`require_new_commits` in distro.toml) and exits 0/1 — CI-consumable. After
a bump: `just prepare && just validate`, build, VM-test, commit the pin.

Implemented in `.github/workflows/release.yml`: daily cron runs the
`--check` gate → bumps the pin (committed by github-actions[bot]) → `just
docked` (AUR cache via actions/cache on `.ii-cache` through II_CACHE_DIR) →
`just smoke` (headless QEMU boot; QMP screendumps must reach ≥16 distinct
colors — text-fallback regressions fail) → rsync ISO + SHA256SUMS to
SourceForge (frs.sourceforge.net, SF_SSH_KEY secret, project
illogical-impulse-iso) → GitHub release with notes + checksums.
workflow_dispatch forces a release from the current pin.

## 8. Easy extensions (designed-for, not yet built)

- **Distro-level fetch.list** — the profile fetch mechanism
  (30-skel.sh) generalizes trivially: read an `overlay/skel-distro.fetch`
  list with the same `<dest> <url> <rev>` format before the profile layer.
- **More editions** — a second profile is just a directory; nothing else
  to wire.

## 9. Bug archaeology

Every design oddity earns its keep — the full list lives in
[CLAUDE.md](../CLAUDE.md) §"Historic bugs encoded in design choices".
Read it before "simplifying" anything in chroot.sh, the Calamares configs,
or the runtime scripts.
