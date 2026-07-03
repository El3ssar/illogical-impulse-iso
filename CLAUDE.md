# Illogical Impulse ISO — Project Map

Custom **Arch-based live ISO** shipping end-4's [Illogical Impulse](https://github.com/end-4/dots-hyprland)
Hyprland/Quickshell rice with a branded Calamares installer. Identifies as its
own distro (`ID=illogical-impulse`, `ID_LIKE=arch`), not plain Arch + dotfiles.

Read this first; the full target design + phase plan is [docs/BLUEPRINT.md](docs/BLUEPRINT.md).
Current state: **phases 1–5 done** (modular pipeline; batteries-included
installer; iictl + welcome card — cheatsheet dropped, upstream has one;
pinned builder container + `just docked`; release CI). The release workflow
(`.github/workflows/release.yml`) runs a **daily cron**: it gates on
`update.sh --check`, **auto-bumps the dots pin and pushes it to `main`** after a
successful release, then builds (`just docked`) → smokes → rsyncs the ISO to
SourceForge (`SF_SSH_KEY` secret) → cuts a GitHub release.

Phase 2 model (revised — no selection screen): the distro ships **batteries
included**. Every default is baked via `packages/goodies.list`; nothing is
asked at install time. The one hardware-conditional piece is NVIDIA: a tiny
flat pacman repo at `/usr/share/illogical-impulse/nvidia` (officials + dep
closure by `chroot.sh`, AUR 580xx legacy staged by `prebuild.sh`) rides in
the squashfs; `ii-post-install` reads `/sys/bus/pci`, matches NVIDIA's vendor
id, then classifies by PCI device id (≥0x1E00 → open, 0x1300–0x1DFF → 580xx
legacy, older → nouveau; supported-gpus.json no longer exists in any package),
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
├── validate.sh                # static audit (~150 checks)
├── update.sh                  # dots submodule bump (+ --check policy gate)
├── vm.sh                      # QEMU/OVMF boot of out/*.iso
├── chroot.sh                  # → /root/customize_airootfs.sh in mkarchiso
├── runtime/                   # → airootfs /usr/local/bin
│   ├── ii-session             # live greetd command (purged on install)
│   ├── ii-launch-installer    # live Calamares wrapper (purged)
│   ├── ii-live-welcome        # live "Install to disk" notification (purged)
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
    ├── sources.sh             # multi-source list-manager substrate (#48): manifest helpers + drop-in source discovery/dispatch + baseline reversibility recorder
    ├── sources.d/<name>       # ★ source resolvers (antidote/ohmyzsh/git…) — SOURCED fragments defining ii_source_<name>_candidates(+add/remove/current); one file = one ecosystem, no hardcoded list
    └── iictl.d/<cmd>          # ★ iictl drop-in subcommands (pack/revert-all/tweak/plugins/about…) — one file per verb, zero core edits
                               #   tweak = thin bridge → the baked iictl-tui ratatui renderer (over each domain's --spec)
                               #   plugins = the #48 multi-source list manager over the ii-owned ~/.config/zsh/ii-plugins.txt manifest
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
| Choose/change the Neovim distro (reversible) | `iictl nvim set <lazyvim\|astronvim\|nvchad\|kickstart\|plain\|restore>` — drop-in `scripts/runtime-lib/iictl.d/nvim`; baked default is vanilla nvim (empty `~/.config/nvim`, the unowned seam), clones a distro ONLINE at a pinned rev, `.ii-distro`-stamped + ledger-recorded, `--force` to replace a non-stamped config; `iictl nvim restore`/`iictl revert-all` returns to bare. NOTHING nvim is baked into the ISO. |
| Choose/change the login shell (reversible) | `iictl shell set <fish\|zsh\|bash\|fizsh\|nushell>` — drop-in `scripts/runtime-lib/iictl.d/shell` (#15). **Default login shell STAYS fish** (Calamares `users.conf`); switching is one-command opt-in. Installs the shell online if missing (official via pacman, AUR via paru), registers `/etc/shells`+`chsh` via the shared `ii_chsh` mutator (records prior shell), and materializes a themed init from baked templates `overlay/airootfs/usr/share/illogical-impulse/shells/{zshrc,zshenv,fizshrc,config.nu}` into the user's UNOWNED slot. Themed zsh ships as home-root `overlay/skel-distro/.{zshrc,zshenv}` (sources `~/.config/zshrc.d/*` READ-ONLY, cats the EXACT `~/.local/state/quickshell/user/generated/terminal/sequences.txt`, GUARDED `antidote load` of `~/.config/zsh/ii-plugins.txt`). fish enrichment lives in the excluded `overlay/skel-distro/.config/fish/conf.d/ii-*.fish` slot. antidote vendored to `~/.antidote` via `overlay/skel-distro.fetch`; offer-only shells in `packages/optional/shells.list`. `iictl shell plugins` delegates to the #48 `iictl plugins` manager; `iictl shell prompt`, `theme`, `--spec`. Reversible via existing ledger kinds (chsh/pkg/path) — `iictl shell set fish` / `iictl revert-all` restore vanilla fish. Touches NO upstream rsync --delete tree (config.fish/zshrc.d only sourced). |
| Curated default web apps for `iictl webapp seed` / change the webapp launcher | `overlay/airootfs/usr/share/illogical-impulse/webapps/defaults.list` (`<name>\|<url>[\|icon]`, opt-in) + `scripts/runtime-lib/iictl.d/webapp` (Brave `--app` `.desktop` in unowned `~/.local/share/applications/`; accent rule fenced ONLY into `~/.config/hypr/custom/rules.lua` via `ii_lua_block_write`; fallback icon `webapps/fallback.png`) |
| Curated app-group installer (picker) | `scripts/runtime-lib/iictl.d/install` — thin picker over `packages/optional/*.list` that delegates to the **online** pack engine (`iictl pack install <group>`; official repos + AUR — never a stash / `[ii-extra]`) |
| Choose the terminal emulator / multiplexer (reversible, #23) | `iictl tui term <kitty\|ghostty\|wezterm\|alacritty\|foot>` / `mux <zellij\|tmux\|none> [--autostart]` / `status` — drop-in `scripts/runtime-lib/iictl.d/tui`; `term` writes a sentinel-fenced `terminal=` **FALLBACK LIST** (chosen first + upstream's chain) run through upstream's `launch_first_available.sh` into the preserved `custom/variables.lua` slot via `ii_lua_block_write` (so uninstalling the pick degrades instead of breaking `Super+Return`; installs a missing emulator ONLINE per pack rules), `mux` autostart is opt-in unowned shell drop-ins (`fish/conf.d/ii-mux.fish`, `~/.config/zsh/ii-mux.zsh`, ledger `kind=path`). kitty stays the explicit default. Baked UNOWNED zellij config: `overlay/skel-distro/.config/zellij/{config.kdl,layouts/ii.kdl}`. **NO per-emulator recolour renderer** — upstream's `applycolor.sh apply_anyterm()` OSC-broadcasts Material You to every emulator; `iictl tweak tui` renders the chooser; `iictl revert-all` strips the fence + drop-ins. |
| Add a Quickshell desktop widget (framework, #20) | `overlay/airootfs/usr/share/illogical-impulse/widgets/<name>/shell.qml` (+ `<name>.json` meta, optional `cards/*.sh` helpers) — a **standalone** `qs -p` config composing `widgets/_lib/{Theme,Panel}.qml`, with **ZERO** `quickshell/ii` imports (clone `welcome/shell.qml`). The registry is a dir scan, so it auto-registers. `iictl widget enable/disable/toggle/list` (`scripts/runtime-lib/iictl.d/widget`) manages per-user markers under `~/.local/state/illogical-impulse/widgets/` + a sentinel-fenced autostart block (`custom/execs.lua`) + the `SUPER+ALT+W` leader submap (`custom/keybinds.lua`), both via the shared mutator (ledger-recorded). `_lib/Theme.qml` watches upstream's generated `colors.json` READ-ONLY. Do NOT rebuild upstream surfaces (pomodoro/notes/clipboard/colorpicker). |
| Add a command-palette action (distro verb, #20) | `overlay/skel-distro/.config/illogical-impulse/actions/<name>.sh` (executable, shebanged) — upstream's `LauncherSearch.qml` auto-loads `~/.config/illogical-impulse/actions/*.sh` via a `FolderListModel` and runs each with `Quickshell.execDetached`; the display name is the filename **without** `.sh`. Distro verbs ONLY — never duplicate an upstream palette category (clipboard/emoji/math/web-search/shell-command). `~/.config/illogical-impulse/` is the UNOWNED seam; never edit `LauncherSearch.qml`/`SearchBar.qml`. |
| Update channels (stable=pinned `DOTS_COMMIT` / edge=HEAD) | `cmd_update` in `scripts/runtime/iictl` (edits LOCAL to that built-in) + `CHANNEL=stable` in the `scripts/prepare.d/70-assets.sh` release stamp; the stable pin is the stamp's `DOTS_COMMIT`, bumped via `just update` — `scripts/validate.sh` asserts stamp pin == submodule HEAD (anti-rot) |
| Add a one-time migration (Omarchy-style) | a baked `overlay/airootfs/usr/share/illogical-impulse/migrations/NNNN-name.sh` (sourced by the `iictl migrate` drop-in; reversible via the shared mutators; applied high-water mark in `$XDG_STATE_HOME/illogical-impulse/migrations.applied`) — see that dir's README |
| Edit the offline quickstart (`iictl docs`) | `overlay/airootfs/usr/share/illogical-impulse/docs/quickstart.md` (printed by the `iictl docs` drop-in) |
| Export/import a whole reversible setup | `iictl config export/import` (drop-in `scripts/runtime-lib/iictl.d/config`) — bundles the ledger TSV + `*.choice` files (tar/awk/cut, no jq), replays through the per-verb engines |
| Give a domain an interactive configurator (TUI) | the domain's `iictl.d/<cmd>` emits `--spec` (the 3-control chooser contract: `choice`/`list`/`toggle`; see BLUEPRINT §"iictl chooser contract") + a `#spec:` header; the baked `iictl-tui` (ratatui) renders it via `iictl tweak <domain>`. The renderer mutates nothing — it shells back to the domain's `iictl` verbs, so the ledger still owns reversibility. |
| Add a NEW plugin-source ecosystem (antidote/ohmyzsh/git…) | `scripts/runtime-lib/sources.d/<name>` — a SOURCED bash fragment defining `ii_source_<name>_candidates` (mandatory; prints candidate manifest lines) and optionally `_add`/`_remove`/`_current` (else they fall through to the shared `ii_manifest_*` helpers in `sources.sh`). Auto-discovered — no edit to `iictl.d/plugins` or the `iictl-tui` renderer. |
| Manage zsh plugins (add/remove from any source) | `iictl plugins {list,sources,candidates,add,remove,--spec,--revert}` or `iictl tweak plugins` (the shared chooser); the ii-owned manifest is `~/.config/zsh/ii-plugins.txt` (`scripts/runtime-lib/iictl.d/plugins`, #48) |
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
- **`services-systemd` schema is `units:`**, not `services:/targets:`. The
  wrong keys make Calamares silently drop every entry (no service enabled);
  `validate.sh` guards the staged conf (strips comments first so the schema-note
  prose can't satisfy/trip the grep) — IMMUNE-01.
- **Live tmpfs gnupg mount surviving install** → broken keyring.
  `ii-post-install` removes the mount unit; the on-disk keyring survives.
  `validate.sh` guards that ii-post-install still drops
  `etc-pacman.d-gnupg.mount` — IMMUNE-01.
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
- **Pack removal `-Rns`-ing the recorded set aborts on a shared dep; pack
  side-effect rows linger** → a pack's recorded set is members + the deps they
  pulled; if another installed pack still needs one of those deps, a blind
  `pacman -Rns $set` aborts the WHOLE (atomic) transaction and the user saw only
  a generic "failed" (stderr swallowed). `revert-all`'s `pkg|pack` inverse now
  routes through `_revert_pkgset`: it drops already-gone members, filters to the
  SAFELY-removable subset (skips any dep still "Required By" an installed package
  outside the set — leaving a shared dep installed for the pack that needs it),
  and SURFACES pacman's stderr on failure. Separately, a pack's `post-add` hook
  records side-effect rows (service/group/chsh/lua-block) keyed on the affected
  OBJECT, not on `pack:<name>`, so `iictl revert-all pack:<name>` never matched
  them and they lingered forever. The pack engine now exports
  `II_PACK_TAG=pack:<name>` around the post-add hook; the mutators stamp that tag
  into the row's otherwise-unused `packages` column (column 4 — never read for
  non-package kinds, so the package-removal inverse is unaffected), and
  `revert-all`'s per-feature filter (`_row_in_filter`) sweeps a tagged row with
  the pack. `validate.sh` guards both halves (REV-04). Don't drop the tag or the
  removable-subset filter — a shared-dep pack remove must succeed, not abort.
- **`welcomeStyleCalamares: false`** hides `productWelcome` — keep `true` in
  `branding.desc`. `validate.sh` guards the staged value is `true` AND that the
  sibling `stylesheet.qss` carries no inert wrong `false` copy (it is a branding
  key, a no-op in a `.qss`, but a misleading drift) — IMMUNE-01.
- **prebuild wiping cache before makepkg succeeds** → empty cache on
  failure. The wipe lives INSIDE `_build` after success.
- **Detached `.sig` fed to `repo-add`** → on a signing-enabled host
  (`BUILDENV+=sign` / a `GPGKEY`), `makepkg` drops a `*.pkg.tar.zst.sig` beside
  each artifact; `repo-add` rejects it (`not a package file`) and, under
  `set -e`, aborts the whole build. Every `*.pkg.tar.*` glob in `prebuild.sh`
  that feeds `repo-add` or the nvidia stash filters `.sig` (mirrors
  `chroot.sh`'s `_nv_pkgs`); `validate.sh` guards it (BUILD-01).
- **Unpinned archiso silently dropping the `customize_airootfs.sh` hook** →
  `chroot.sh` is staged as `/root/customize_airootfs.sh` and run by `mkarchiso`
  via a mechanism `mkarchiso` ITSELF warns is deprecated ("Support for it will be
  removed in a future archiso version"); archiso is pulled from the host package.
  If a host bump drops the hook, the entire keyring/paru/wheelhouse/liveuser-seed/
  microcode-stash/sanity-gate bootstrap SILENTLY stops running — the ISO still
  BUILDS but ships broken. `containers/builder.Dockerfile` PINS archiso
  (`ARCHISO_PIN`) and fails its own image build if the pinned `mkarchiso` no
  longer references `customize_airootfs.sh`; `mkiso.sh` re-checks the actually-
  installed `mkarchiso` at build time and dies loudly; `validate.sh` guards both
  halves and probes the live binary when present (BUILD-05). To bump archiso,
  raise `ARCHISO_PIN` only after re-confirming the hook survives. Don't unpin or
  drop the guard — a host bump must fail LOUDLY, not silently.
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
- **Smoke test under TCG (no KVM) hangs to a misleading timeout** → the smoke
  probe boots the ISO into a full graphical session and counts framebuffer
  colours; that cold boot never completes in time under TCG software emulation.
  `ubuntu-latest` exposes `/dev/kvm` but the runner user isn't in the `kvm`
  group, so `[[ -w /dev/kvm ]]` failed and `smoke.sh` silently dropped to TCG.
  `release.yml` now adds the standard "Enable KVM access" udev step
  (`99-kvm4all.rules`, `MODE="0666"`) before the smoke step so the boot is
  hardware-accelerated; `smoke.sh` **fails fast** with a clear "KVM required for
  the graphical probe" message when `/dev/kvm` is unavailable (set
  `SMOKE_ALLOW_TCG=1` to force the slow TCG path with eyes open) rather than
  hanging. `validate.sh` guards both halves (CI-03).
- **Installer purge hardcoded, decoupled from `installer.list`** → the live-only
  installer set (calamares, kpmcore…) is BAKED via `packages/installer.list` and
  PURGED from the target by `ii-post-install`. A hardcoded `calamares kpmcore` in
  the purge would leak any *third* `installer.list` entry onto every installed
  system. `40-packages.sh` now stages the parsed installer names into the
  squashfs at `/usr/share/illogical-impulse/installer-purge.list`;
  `ii-post-install` reads that file (removing it after), falling back to the
  baked-in default only if it is missing. `validate.sh` guards both halves — the
  staged list covers every `installer.list` pkg AND ii-post-install consumes it
  (IMMUNE-01).
- **Second hardcoded copy of upstream's `firstRunFileContent`** → besides the
  skel seed (its own guard), `ii-post-install` carries a *fail-safe* `printf
  "<text>\n" > "$FRUN"` literal for the rare case skel didn't seed the marker.
  If upstream retexts the string, that literal silently writes foreign content
  into upstream's STATE path. `validate.sh` cross-checks the printf literal
  against upstream's `FirstRunExperience.qml` `firstRunFileContent` — IMMUNE-01.
- **Runtime syntax loop missed three shipped helpers** → `validate.sh`'s
  `bash -n` loop omitted `ii-ensure-venv`, `ii-build-wheelhouse`,
  `ii-live-welcome`, so a syntax error in any of them shipped green. All three
  are now in the loop — IMMUNE-01.
- **`((var++))` under `set -e`** → post-increment of a zero variable returns 1,
  so `set -e` silently kills the script (cost a real two-kernel install; see the
  `NOT ((copied++))` caution in `ii-prepare-bootloader`). The idiom is now banned
  by a `validate.sh` lint over `scripts/runtime/` + `scripts/prepare.d/` (use
  `var=$((var + 1))`); the two stale occurrences (`60-boot.sh`, `ii-verify`) were
  converted — IMMUNE-01.
- **Broken Quickshell venv stranded on online-only recovery** → the venv
  (`~/.local/state/quickshell/.venv`, Pillow + materialyoucolor on a uv-managed
  CPython 3.12 from `/usr/share/uv/python`) is built at install by
  `ii-post-install` via `ii-ensure-venv` off the baked wheelhouse. The whole
  offline mechanism is sound (managed-python discovery, wheelhouse, import all
  verified end-to-end under empty-cache/no-network conditions), BUT that step is
  fail-soft (`try`) — so an install-time failure (the sudo-pty bug below, INST-05)
  could leave the venv broken — and
  `ii-verify` used to `rm -rf /usr/share/ii-python-wheels` + delete
  `ii-ensure-venv` UNCONDITIONALLY, never checking the venv. So a one-off failure
  became permanent and recoverable only online (and `iictl venv` was itself
  online-only, relying on profile.d for `UV_PYTHON_INSTALL_DIR`). `ii-verify` now
  GATES that purge on the venv: it runs the `import materialyoucolor, PIL` check,
  attempts one offline rebuild via `ii-ensure-venv`, and on continued failure
  KEEPS the wheelhouse + `ii-ensure-venv` (a broken venv is a `warn`, never a hard
  FAIL — the system still boots; only first-boot colour gen is affected). `iictl
  venv` now sets `UV_PYTHON_INSTALL_DIR` itself and delegates to `ii-ensure-venv`
  / prefers `--find-links` the wheelhouse (offline) before any online path.
  `validate.sh` guards both halves (INST-04). Don't restore the unconditional
  purge or make `iictl venv` online-only.
- **Widget framework: `SUPER+W` is taken upstream; fences are runtime-only, not
  baked into skel** → the Quickshell widget framework (#20) reaches the user via a
  leader keybind. Issue #20 proposed `SUPER+W`, but upstream `keybinds.lua` already
  binds `SUPER+W` to the browser, so `iictl widget` claims the deconflicted
  `SUPER+ALT+W` instead (audit-before-reserve). Crucially the autostart block
  (`custom/execs.lua`) and the leader submap (`custom/keybinds.lua`) are written at
  RUNTIME by `iictl widget enable` through the shared `ii_lua_block_write` mutator
  (ledger-recorded) — they are **deliberately NOT seeded into `/etc/skel`**: the
  framework is dormant/vanilla until the user opts in, and a static skel
  `keybinds.lua` would SHADOW upstream's non-empty stub (the "Edit user keybinds"
  bind) — an Iron-Law violation. `validate.sh` guards that no widget fence is baked
  into skel and that every fence write goes through the mutator (#20). The card
  helper logic lives in real `widgets/devdash/cards/*.sh` files (bash -n lintable),
  not embedded in QML, so escaping never silently breaks a card. Don't bake the
  fences or change the leader back to bare `SUPER+W`.
- **`sudo -u` in the Calamares chroot can't allocate a pty** → modern sudo runs
  the command in a PTY (`Defaults use_pty`), but the Calamares target chroot has
  no `/dev/pts`, so every `sudo -u "$NEW_USER" …` in `ii-post-install` dies with
  `sudo: unable to allocate pty: No such device` and rc=1 — silently (fail-soft)
  skipping the Quickshell venv build (the root cause of the INST-04 incident on
  a real install) AND both revert ledger records (first-run-welcome marker +
  welcome exec-hook fence, so `iictl revert-all` couldn't undo them). It worked
  at BUILD time only because mkarchiso's `arch-chroot` mounts `/dev/pts`;
  `chroot.sh`'s `sudo -u liveuser` is therefore fine and is deliberately left
  as-is. `ii-post-install` and `ii-verify` (its venv self-heal) now drop to the
  user via **`runuser -u "$NEW_USER" --`** (util-linux; allocates no PTY, needs
  no sudoers/PAM-auth) instead, carrying the user env explicitly. `validate.sh`
  fails on any `sudo -u` in those two Calamares-chroot scripts (INST-05). Don't
  reintroduce `sudo -u` there — use runuser.

## 6a. Known limitations (documented stances, not yet implemented)

- **Secure Boot is unsupported — disable it to boot/install.** Neither the live
  media nor `ii-finish-systemd-boot` signs or enrolls anything: the installed
  system gets a plain unsigned systemd-boot setup, and `smoke.sh` boots with SB
  off. On an SB-enabled machine firmware rejects the unsigned binaries.
  The documented stance (README → "Secure Boot" + "Known issues") is: **turn
  Secure Boot off** before booting the ISO and leave it off. `sbctl`/`shim`
  enrollment in `ii-finish-systemd-boot` plus an SB-enabled smoke variant is a
  planned future step (issue #83 / HW-02); SB-enabled installs are currently
  untested. Don't claim SB support until that lands.

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
