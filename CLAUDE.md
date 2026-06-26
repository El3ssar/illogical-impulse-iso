# Illogical Impulse ISO — Project Map

Custom **Arch-based live ISO** shipping end-4's [Illogical Impulse](https://github.com/end-4/dots-hyprland)
Hyprland/Quickshell rice with a branded Calamares installer. Identifies as its
own distro (`ID=illogical-impulse`, `ID_LIKE=arch`), not plain Arch + dotfiles.

Read this first; the full target design + phase plan is [docs/BLUEPRINT.md](docs/BLUEPRINT.md).
Current state: **phases 1–3 done** (modular pipeline; batteries-included
installer; iictl + welcome card — cheatsheet dropped, upstream has one).
Phases 4–5 (container build, CI) are pending.

Phase 2 model (revised — no selection screen): the distro ships **batteries
included**. Every default is baked via `packages/goodies.list`; nothing is
asked at install time. The one hardware-conditional piece is NVIDIA: a tiny
flat pacman repo at `/usr/share/illogical-impulse/nvidia` (officials + dep
closure by `chroot.sh`, AUR 580xx legacy staged by `prebuild.sh`) rides in
the squashfs; `ii-post-install` reads `/sys/bus/pci`, matches NVIDIA's
classifies by PCI device id (≥0x1E00 → open, 0x1300–0x1DFF → 580xx legacy,
older → nouveau; supported-gpus.json no longer exists in any package),
installs the right variant offline or nothing, then deletes the stash. Rule: mkiso.sh (root) never writes into
build/ — user-level staging belongs in prebuild.sh.

---

## 1. The philosophy in one paragraph

The build merges **two sources** and applies **one overlay**: the archiso
releng profile (from the installed `archiso` package) + the
`upstream/illogical-impulse` submodule (dots + PKGBUILD dependency
declarations), with `overlay/` layered on top for everything distro-specific.
Identity strings live ONLY in `distro.toml`. Personal customization never
touches `overlay/` — it goes in `profiles/<name>/`.

## 2. Repo layout

```
distro.toml                    # ★ single source of truth: identity + knobs
justfile                       # ★ the only entry point (no Makefile)
packages/
├── base.list                  # distro baseline (live + installed)
├── installer.list             # purged from target by ii-post-install
├── goodies.list               # curated always-installed extras (small!)
├── nvidia.list                # hardware-detected at install — never baked
└── optional/<pack>.list       # FETCHED-ONLINE packs — only the name-list ships; `iictl pack` installs on demand
profiles/<name>/               # personal layers (skel/, packages.list, fetch.list)
overlay/
├── pacman.conf                # HOST pacman.conf — includes [ii-extra]
├── airootfs/                  # raw files → squashfs (greetd, identity, drop-ins)
├── skel-distro/               # distro dotfile defaults on top of upstream dots
├── skel-live/                 # liveuser-only (installer icon, live keybinds)
├── calamares/                 # settings.conf + modules/ + branding/
├── efiboot/                   # live systemd-boot menu
├── assets/                    # wordmark.svg, default-wallpaper.png
└── aur-pkgbuilds/             # local PKGBUILD overrides + the iictl-tui Rust crate
scripts/
├── lib/{common.sh,toml-get}   # shared env + distro.toml reader
├── prepare.sh + prepare.d/    # 10-releng 20-airootfs 30-skel 40-packages
│                              # 45-optional-packs 50-calamares 60-boot 70-assets
├── prebuild.sh                # AUR/local pkgs → /var/cache/ii-extra-repo
├── mkiso.sh                   # mkarchiso wrapper (self-sudo)
├── validate.sh                # static audit (~55 checks)
├── update.sh                  # dots submodule bump (+ --check policy gate)
├── vm.sh                      # QEMU/OVMF boot of out/*.iso
├── chroot.sh                  # → /root/customize_airootfs.sh in mkarchiso
├── runtime/                   # → airootfs /usr/local/bin
│   ├── ii-session             # live greetd command (purged on install)
│   ├── ii-launch-installer    # live Calamares wrapper (purged)
│   ├── ii-ensure-venv         # venv from offline wheelhouse
│   ├── ii-build-wheelhouse    # chroot-only wheelhouse builder
│   ├── ii-prepare-bootloader  # Calamares: kernels + microcode + initramfs
│   ├── ii-finish-systemd-boot # Calamares: loader entries, LUKS, resume=
│   ├── ii-post-install        # Calamares: greetd, groups, purges, venv
│   ├── ii-verify              # Calamares: final gate + ISO-helper purge
│   └── iictl                  # ★ distro CLI — SURVIVES install; sources iictl-common.sh,
│                              #   execs iictl.d/<cmd> drop-ins (update/doctor/venv/welcome inline)
└── runtime-lib/               # → /usr/local/lib/ii (SURVIVES install, except session-offline.sh)
    ├── session-offline.sh     # ISO-only ii_* session helpers (purged by ii-verify)
    ├── iictl-common.sh        # shared iictl/plugin header (colors, ok/die, ledger, plugin contract)
    ├── ledger.sh              # append-only TSV state ledger (record/query/owned_paths; the reversibility manifest)
    ├── mutator.sh             # idempotent reversible ledger-recording primitives (service/group/chsh/lua-block fence/conflicts)
    └── iictl.d/<cmd>          # ★ iictl drop-in subcommands (pack/revert-all/tweak/about…) — one file per verb, zero core edits
                               #   tweak = thin bridge → the baked iictl-tui ratatui renderer (over each domain's --spec)
tools/                         # manual: gen-assets.sh, resolve-deps.py
upstream/illogical-impulse     # dots submodule — DO NOT EDIT
build/ out/                    # generated
```

## 3. Pipeline

`just build [profile]` = `prepare` → `prebuild` → `mkiso`:

1. **prepare** (`prepare.d/*` in order): releng baseline from
   `/usr/share/archiso/configs/releng` → overlay/airootfs + runtime scripts →
   skel layer cake → packages.x86_64 (upstream PKGBUILD deps scraped by
   `tools/resolve-deps.py` + our manifests, AUR names accumulated for
   prebuild) → optional pack name-lists staged as text (never baked;
   `45-optional-packs`) → Calamares staging → efiboot + profiledef.sh generated from
   distro.toml → generated os-release + `/etc/illogical-impulse/release`
   stamp + default wallpaper.
2. **prebuild**: per-package cache decision (`*-git` always; local PKGBUILD
   by pkgver; AUR by RPC version; RPC failure → trust cache), `makepkg` into
   staging, atomic swap, `repo-add` → `[ii-extra]`. Wipes stale entries only
   AFTER a successful build.
3. **mkiso**: `mkarchiso` pacstraps from `build/packages.x86_64` +
   `[ii-extra]`, runs `chroot.sh` inside the airootfs (keyring, paru,
   wheelhouse, +x repair, liveuser seed from skel-upstream+skel-live,
   microcode stash, sanity gate), squashes, emits `out/*.iso`.

## 4. The skel layer cake

```
/etc/skel-upstream  = upstream dots (synced verbatim)          → liveuser
/etc/skel           = skel-upstream + overlay/skel-distro
                      + profiles/$PROFILE/skel (last wins)     → installed user
/etc/skel-live      = overlay/skel-live                        → liveuser only
```

- liveuser is seeded by `chroot.sh` from skel-upstream + skel-live — it never
  sees skel-distro or profile overrides.
- Installed users get `/etc/skel` via Calamares `useradd -m`.
- `unpackfs.conf` excludes skel-upstream, skel-live, and /home/liveuser.
- Profile `fetch.list` (`<dest> <git-url> <rev>`) clones pinned repos into the
  skel at prepare time (cached in `.fetch-cache/`) — no nested git checkouts
  in this repo.

## 5. Where to edit (quick lookup)

| Want to… | File |
|---|---|
| Rename/rebrand the distro, change version scheme, repo name | `distro.toml` |
| Always-installed package (small + universal only) | `packages/goodies.list` (or `base.list` if infra) — heavy/non-universal bakes get a budget WARN |
| Offer a heavy/opinionated package (online, on-demand) | `packages/optional/<pack>.list` (curated name-list; `iictl pack install/remove/list` installs it from the internet — official repos + AUR — never baked or stashed; staged by `45-optional-packs`) |
| Give a pack an install/remove side effect (service, group, fenced lua) | `packages/optional/<pack>.d/post-add` + `post-remove` — bash fragments **sourced** by `iictl pack`; `post-add` applies effects via the shared mutators (ledger-recorded), the symmetric `post-remove` undoes them on `iictl pack remove` |
| NVIDIA driver variants | `packages/nvidia.list` (auto-detected at install) |
| Personal package/dotfile | `profiles/<you>/{packages.list,skel/}` |
| Override an installed-user dotfile (distro-wide) | `overlay/skel-distro/<path>` |
| Vendor a pinned third-party tree distro-wide | `overlay/skel-distro.fetch` (`<dest> <git-url> <rev>`, distro-owned paths only) |
| Live-session-only file | `overlay/skel-live/<path>` |
| System file (greetd, systemd drop-in, passwd, motd…) | `overlay/airootfs/<path>` |
| Live boot menu | `overlay/efiboot/loader/` |
| Calamares branding / module config / sequence | `overlay/calamares/…` (mind `instances:`) |
| Live session entry | `scripts/runtime/ii-session` |
| ISO-build chroot logic | `scripts/chroot.sh` |
| Post-install / bootloader / verify logic | `scripts/runtime/ii-*` |
| Add an iictl subcommand (drop-in) | `scripts/runtime-lib/iictl.d/<cmd>` (exec; `source "${II_LIB:-/usr/local/lib/ii}/iictl-common.sh"` + a `#help:` line) → staged to `/usr/local/lib/ii/iictl.d/` |
| Give a domain an interactive configurator (TUI) | the domain's `iictl.d/<cmd>` emits `--spec` (the 3-control chooser contract: `choice`/`list`/`toggle`; see BLUEPRINT §"iictl chooser contract") + a `#spec:` header; the baked `iictl-tui` (ratatui) renders it via `iictl tweak <domain>`. The renderer mutates nothing — it shells back to the domain's `iictl` verbs, so the ledger still owns reversibility. |
| Change/extend the `iictl-tui` renderer | `overlay/aur-pkgbuilds/iictl-tui/crate/` (Rust/ratatui; built by prebuild → `[ii-extra]`, baked via `packages/base.list`) |
| Pipeline step | `scripts/prepare.d/NN-*.sh` |
| Default wallpaper / wordmark | `overlay/assets/` (then `just assets`) |

## 6. Historic bugs encoded in design choices

Don't "simplify" these away — each cost real debugging time:

- **/var/lib/greetd missing** → greetd dies. Static
  `overlay/airootfs/etc/tmpfiles.d/greetd-home.conf` creates it every boot.
- **`shellprocess@<id>` without `instances:` mapping** silently loads the
  no-op `shellprocess.conf`. Every instance in `settings.conf` MUST map.
- **mkarchiso `cp --no-preserve=mode`** strips +x in `/etc/skel` →
  `chroot.sh` re-chmods scripts.
- **mkarchiso wipes `/boot/*`** after the chroot hook → microcode stashed at
  `/usr/share/illogical-impulse/boot-stash/`, restored by
  `ii-prepare-bootloader`.
- **Python venv absolute paths** → venvs are created at the real `$HOME`
  only (chroot.sh for liveuser, ii-post-install for the new user), never in
  skel.
- **mkinitcpio 'fallback' preset** commented out upstream →
  `ii-prepare-bootloader` always writes both presets.
- **unpackfs `sourcefs: "squashfs"`** when the source is a directory →
  crash. Must be `"ext4"`.
- **Plymouth + universal initramfs** → black screens. Not shipped; opt-in only.
- **`services-systemd` schema is `units:`**, not `services:/targets:`.
- **Live tmpfs gnupg mount surviving install** → broken keyring.
  `ii-post-install` removes the mount unit; the on-disk keyring survives.
- **Color pregen in chroot races `applycolor.sh`** → we don't pregen; the
  first-boot wallpaper switch (`switchwall.sh`) generates colours in a real
  Hyprland session. We **suppress upstream's FirstRunExperience** (its welcome
  app) so OUR welcome card shows instead — the
  `~/.local/state/quickshell/user/first_run.txt` marker is pre-seeded for the
  **installed user** via `overlay/skel-distro/.local/state` (`30-skel.sh` copies
  it into `/etc/skel`; useradd -m delivers it). It must contain upstream's exact
  `firstRunFileContent` string (validate.sh guards this; never write any other
  content into that STATE path). `ii-post-install` records it in the new user's
  ledger (kind `file`) for `iictl revert-all`. The **liveuser is deliberately NOT
  seeded** (30-skel.sh excludes `first_run.txt` from the skel-upstream state
  copy): it has no distro welcome hook (its `custom/execs.lua` is the installer
  launcher) and `chroot.sh` defers the live wallpaper/colour bootstrap to
  upstream's first-run — suppressing it there would give a Try-live boot no
  wallpaper, no colours, and no welcome. Suppressing it (installed user) ALSO
  kills upstream's first-boot `switchwall`, so
  `iictl welcome --auto` re-runs it itself once (it self-activates the venv via
  `$ILLOGICAL_IMPULSE_VIRTUAL_ENV` from upstream's hypr `env.lua`). A static
  `kitty-theme.conf` in `overlay/skel-distro` covers the gap before it runs.
  Don't "fix" the seed away — without it the upstream welcome reappears.
- **`welcomeStyleCalamares: false`** hides `productWelcome` — keep `true` in
  `branding.desc`.
- **prebuild wiping cache before makepkg succeeds** → empty cache on
  failure. The wipe lives INSIDE `_build` after success.
- **Detached `.sig` fed to `repo-add`** → on a signing-enabled host
  (`BUILDENV+=sign` / a `GPGKEY`), `makepkg` drops a `*.pkg.tar.zst.sig` beside
  each artifact; `repo-add` rejects it (`not a package file`) and, under
  `set -e`, aborts the whole build. Every `*.pkg.tar.*` glob in `prebuild.sh`
  that feeds `repo-add` or the nvidia stash filters `.sig` (mirrors
  `chroot.sh`'s `_nv_pkgs`); `validate.sh` guards it (BUILD-01).
- **`gh release create` with a date-derived tag is not idempotent** → the
  release version is the build DATE, so a same-day cron re-run or a
  `workflow_dispatch` reuses it. `publish-sf.sh` overwrites the SourceForge
  `VER/` folder in place (fine), but an unguarded `gh release create "$VER"`
  errors on the now-existing tag and reds the run — leaving a published ISO on
  SourceForge with no matching GitHub release. `release.yml`'s release step is
  view-or-edit (`gh release edit` + `gh release upload --clobber` when the
  release exists, else create), so re-runs converge on ONE release;
  `validate.sh` guards it (CI-02).
- **Release dots-pin committed/pushed *before* build/publish** → a later
  build/smoke/SourceForge/GitHub-release failure strands a fresh pin on `main`
  with no release; `update.sh --check`'s age gate (`PIN_AGE_DAYS <
  min_days_between_releases`) then reads it as "too young → no bump" and
  suppresses retries for ~15 days. `release.yml` splits the bump: the submodule
  **working tree** is bumped *before* the build (so the ISO ships the new dots),
  but the pin is **committed + pushed to `main` only after a successful GitHub
  release** (the last step; it rebases onto `main` first so the long build
  window can't non-fast-forward-fail). Any earlier failure aborts before that
  step → `main` keeps the old pin → the next cron retries. `validate.sh` guards
  the ordering (CI-01).

## 7. Debug paths

```
# Live ISO (Ctrl+Alt+F2):
cat /var/log/greetd-boot.log /var/log/ii-session.log
journalctl -b -u greetd --no-pager
ls /var/lib/greetd

# Failed install (target chroot):
cat /var/log/ii-post-install.log /var/log/ii-verify.log
cat /var/log/ii-prepare-bootloader.log /var/log/ii-finish-systemd-boot.log

# Build chroot log:
build workdir: /var/tmp/ii-iso-work (kept on mkarchiso failure)
  …/x86_64/airootfs/var/log/customize_airootfs.log
```

## 8. Conventions

- Identity strings: `distro.toml` only. Scripts read it via
  `scripts/lib/toml-get`; nothing else hardcodes the name.
- Runtime/installed-system artifacts use the `ii-` / `ii_` prefix
  (`/usr/local/lib/ii`, `[ii-extra]`, `ii_install` cmdline flag).
- Each `prepare.d` step is single-purpose; add a new step rather than
  growing an existing one.
- `upstream/` is read-only; bump it with `just update` and commit the pin.
