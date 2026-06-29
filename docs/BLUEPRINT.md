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
| Upstream tracking | Pinned submodule. Bump policy = knobs in `[upstream]` of distro.toml, enforced by `update.sh --check` (the `release.yml` daily cron calls the same gate). |
| Build env | Native Arch host, or the pinned builder container via `just docked` (`containers/builder.Dockerfile`). archiso releng baseline comes from the **installed archiso package** (no vendored copy). |
| CI | `validate.yml` runs `just prepare && just validate` per push/PR. `release.yml` automates the release (daily cron → auto-bump pin → `just docked` build → QEMU smoke → publish); ISO hosting target is SourceForge (`SF_SSH_KEY` secret; GitHub caps release assets at 2 GiB). |
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
├── prepare.d/       10-releng 20-airootfs 30-skel 40-packages
│                    45-optional-packs 50-calamares 60-boot 70-assets
├── prebuild.sh      AUR/local PKGBUILDs → /var/cache/ii-extra-repo + staging
├── mkiso.sh         mkarchiso wrapper (self-sudo)
├── validate.sh      static audit (~150 checks)
├── update.sh        submodule bump + --check policy gate
├── vm.sh            QEMU: live / --disk / --installed / --fresh-disk
├── clean.sh         build/ (--hard: + out/ + workdir)
├── chroot.sh        runs INSIDE mkarchiso chroot (customize_airootfs)
├── runtime/         → airootfs /usr/local/bin (live session + Calamares hooks)
└── runtime-lib/     → /usr/local/lib/ii (chroot-safe ii_* helpers + the
                       iictl framework: iictl-common.sh, ledger.sh, iictl.d/<cmd>
                       drop-ins — these SURVIVE install; session-offline.sh is purged)
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
   immune system: ~150 checks, each encoding a real failure mode.
6. **Flat pacman repos** — db and `.pkg.tar.*` share one directory; pacman
   fetches `$Server/$filename`. Filter `.sig` files out of `repo-add`.
7. Runtime/installed artifacts use the `ii-`/`ii_` prefix.

### Seam classes (what may be written, and how it reverts)

Every distro addition targets one upstream-guaranteed seam; the reversibility
of the whole distro rests on respecting their classes. Full table in
[PROPOSAL.md](PROPOSAL.md) §3 — the classes, condensed:

- **`install_dir__ignore_existing`** — the empty
  `~/.config/hypr/custom/{env,execs,general,rules,variables}.lua` slots
  (upstream ships 1-byte stubs and never overwrites). **Every** distro write
  here MUST be **sentinel-fenced** with a named block:

  ```lua
  -- >>> illogical-impulse <name>
  ...our lines...
  -- <<< illogical-impulse <name>
  ```

  so a revert can strip *exactly* our block, leaving the upstream stub and any
  user lines intact. **One shared helper pair owns all reads/writes** —
  `ii_lua_block_write` / `ii_lua_block_remove` in
  `scripts/runtime-lib/mutator.sh` (both share the `_ii_lua_strip` routine);
  no other code hand-appends to these slots, and the helper refuses any
  non-`custom/*.lua` path. `ii_lua_block_write` is idempotent (replaces a
  same-named block instead of duplicating) and records a `lua-block` ledger row;
  `ii_lua_block_remove` is the inverse used by `iictl revert-all`. **`validate.sh`
  enforces** (`step "sentinel-fenced custom/*.lua blocks"`) that no distro
  exec-hook (`hl.on` / `hl.exec_cmd`) appears outside a fence — an unfenced block
  would survive a revert, so it is a build-failing bug. The baked welcome-card
  block in `overlay/skel-distro/.config/hypr/custom/execs.lua` is the canonical
  example — with one wrinkle: it ships **statically** through `skel-distro` →
  `/etc/skel` → `useradd -m`, so it never passes through `ii_lua_block_write` and
  no `lua-block` ledger row is created at write time. `ii-post-install` therefore
  records that row itself for the installed user (target+owned = their
  `custom/execs.lua`, `restore_hint` = the block name `welcome`); that recording
  is what lets `iictl revert-all` strip the fence and restore upstream's empty
  stub (REV-01). `validate.sh`'s welcome step asserts the row is recorded, so a
  static fence can never ship unrevertable.
- **unowned** — `~/.bashrc`, `~/.config/nvim`, `~/.config/{git,btop,bat,…}`,
  `~/Projects` (upstream ships nothing → no collision). Themed tool configs,
  dev defaults, scaffolds.
- **excluded from upstream sync** — `~/.config/fish/conf.d/ii-*.fish`
  (`30-skel.sh` `--exclude=conf.d`); fish auto-loads it, ours are the only files.
- **`install_dir__sync` (`rsync --delete`)** ⚠️ — `~/.config/quickshell/ii`,
  `~/.config/matugen`, `~/.config/fish/config.fish`, `~/.config/zshrc.d`,
  `~/.config/hypr/hyprland`, `starship.toml`, `hyprlock.conf`. Anything we add
  here is **wiped on `iictl update`** → **READ-ONLY**: observe/source, never write.
- **upstream-owned runtime STATE** ⚠️ — `~/.config/illogical-impulse/config.json`
  (the rice's settings file, rewritten at runtime by `switchwall.sh` /
  `applycolor.sh` / the config UI) and the derived theming outputs
  `~/.local/state/quickshell/user/generated/{colors.json,sequences.txt,material_colors.scss}`
  are **owned/written by the rice at runtime**. Note the *directory*
  `~/.config/illogical-impulse/` is itself an unowned seam (safe for OTHER
  files — see the unowned row above); `config.json` *specifically* is runtime
  STATE. This is *distinct* from the `rsync --delete` *config* dirs above: those
  are source config we must not add to; these are runtime STATE we must not seed.
  **Never pre-seed them in skel** (a static `kitty-theme.conf` fallback is the
  one sanctioned exception, and even it carries no placeholders — see
  §"Historic bugs" in CLAUDE.md).
  Theming features observe via `FileView` read-only and only call upstream
  public entry points (`switchwall.sh`, `qs ipc`), recording the prior value in
  the ledger so a revert restores it.
- **reserved, NOT baked** — `packages/optional/*.list`: curated **name-lists**
  installed on demand from the internet by `iictl pack` (official repos + AUR).
  Only the few-KB list rides in the squashfs — never the packages themselves.
  The verb (`scripts/runtime-lib/iictl.d/pack`): `iictl pack list [--json]`
  enumerates packs with installed/conflict status (no root, no network);
  `iictl pack install <pack>` classifies each member at runtime (`pacman -Si`),
  installs official members via `sudo pacman -S --needed` and AUR members via
  **paru** (presence-checked, bootstrap-or-error — its ISO build is fail-soft),
  enforces `#meta:conflicts` via `ii_conflicts_check` **before** any pacman runs,
  and `ledger_record`s the *resolved* set (a `kind=pack`, `target=pack:<name>`
  row); `iictl pack remove <pack>` runs the pack's optional `post-remove` hook
  (the inverse of any side effects) and delegates the package removal to
  `iictl revert-all pack:<pack>` (the single replay owner — offline-safe
  `pacman -Rns`). `validate.sh` forbids one pack name being a prefix of another
  so that delegated `pack:` prefix filter stays exact per-pack; a full
  `iictl revert-all` remains the global catch-all (sweeps any side-effect rows
  too). A pack may ship `<pack>.d/post-add|post-remove` bash fragments (sourced,
  with the shared mutators in scope) for ledger-recorded side effects.
- **survives install** — `/usr/local/bin/iictl` (named-exempt from the
  `ii-verify` purge): the post-install config surface for every feature.

### The bake / fetch budget governor (HARD gate)

The ISO is already ~5.8 GB — over GitHub's **2 GiB** release-asset cap (it ships
via SourceForge), so every "just bake it" decision compounds the distribution
problem. Two tiers govern where a payload lands:

- **BAKED** — in the squashfs, always installed. *Only small + universal*
  things (`packages/goodies.list`, `packages/base.list`): the dev baseline
  (gh / git-delta / direnv / just / mise), distrobox, emoji font, the
  cups/bluez/sane stack, themed shell+tool configs (config text is KB), the
  Control Center + welcome QML, `iictl.d` + ledger. Net add: a few hundred MB.
- **FETCHED-ONLINE** — installed on demand over the network by `iictl`
  (`iictl pack`/`iictl pkg`: official repos via `pacman`, AUR via paru).
  **Everything heavy/opinionated**: language runtimes, gaming, virt, security,
  AUR shells/tools, nvim distros + plugins, and the bulky long tail (wallpaper
  packs, LSP servers, editor extensions, AI models, DaVinci/waydroid). Only the
  curated few-KB name-list (`packages/optional/*.list`) rides in the squashfs —
  **never the dependency closure.** `[ii-extra]` is build-host-only and does
  **not** survive install, so the install path is the public mirrors + AUR,
  never an on-ISO repo. (Optional software thus needs a network at install-time
  — an accepted trade for not bloating every image with software most users
  won't want.)

> **The one on-ISO repo exception** is the **NVIDIA driver stash**
> (`chroot.sh` → `/usr/share/illogical-impulse/nvidia`): hardware drivers are
> tiny, hardware-conditional, and must work at first boot before a network may
> exist. It is a bounded exception, **not** a pattern to mirror for software
> packs — an earlier draft did exactly that and would have hauled multiple GB
> of optional closures into every image and every installed system.

Rule of thumb: anything **> ~150 MB installed footprint** that isn't universal
is **FETCHED-ONLINE, never BAKED** (and never stashed into the image).
`validate.sh` enforces a **soft** version of this in the
`step "bake/fetch budget governor"` section: it **WARNs (non-fatal)** when a
heavy/non-universal package appears in `goodies.list`, keyed off an allowlist of
the sanctioned flagships plus a heavy-name heuristic. The WARN never fails the
build (legitimate flagship bakes still pass) — it surfaces *new* heavy additions
so the author confirms the tier. The discipline is what lets the distro be
genuinely *batteries-included* while staying distributable: universal batteries
baked, every heavy choice one reversible command away.

### Reversibility engine — `iictl revert-all` (two-tier) + per-feature `--revert`

`iictl revert-all` (`scripts/runtime-lib/iictl.d/revert-all`) is what makes the
Iron Law demonstrable: it reads the TSV ledger newest-first and dispatches each
recorded `kind` to its inverse **through the shared `mutator.sh`/`ledger.sh`
helpers** — `lua-block` → `ii_lua_block_remove` (never a bespoke `sed`/`rm`),
`service`/`service-disable` → `systemctl disable`/`enable`, `group` →
`gpasswd -d`, `chsh` → restore prior shell, `pkg`/`pack` → offline `pacman -Rns`
(no network, no `[ii-extra]`), `path` → remove owned paths, `skel-shadow` →
restore the upstream copy. It is fail-soft (a failed inverse warns, is left in
the ledger, and the replay continues), then re-runs `iictl doctor`. Successfully
undone rows are pruned from the ledger; only skipped/failed rows remain.
`validate.sh`'s `step "revert-all reversibility engine"` enforces the
no-bespoke-stripping bug-class.

- **Two-tier (`--deep`)** — the default scope undoes *iictl-time* user choices
  (the common case). `--deep` additionally peels *install-time* distro setup
  recorded by `ii-post-install` (the six baseline group memberships
  `video input i2c render audio wheel` plus the `docker` group). A row is
  install-time iff its `restore_hint` carries the reserved **`src=install`**
  token (the forward-compatible marker any install-flow recorder appends)
  **or** it matches a known ii-post-install signature (the `group docker` compat
  shim for legacy ledgers written before the marker — kept so an already-shipped
  install still gates docker under `--deep`; extend the shim as `ii-post-install`
  grows its reversible setup, or append `src=install` to new install-time rows).
  Install-flow group adds opt in via `ii_group_add` (`mutator.sh`) with
  **`II_GROUP_SRC=install`** in the environment — it appends `src=install` to the
  `user=<u>` hint (the two tokens are space-separated and order-independent;
  revert-all extracts `user=` by token scan so they never collide). `wheel` is
  load-bearing — it makes the baked nopasswd-sudo drop-in effective — so it is
  deliberately install-tier: a plain `iictl revert-all` leaves it, only `--deep`
  peels it. Pack post-add hooks call `ii_group_add` *without* `II_GROUP_SRC`, so
  their memberships are iictl-tier (a plain revert undoes them).
- **`--dry-run`** prints the ordered plan and makes zero changes (the codepath a
  future Control Center "preview revert" reuses).
- **Per-feature `--revert`** — a domain plugin reverts just its own ledger rows
  by exec'ing `iictl revert-all <target>`, where `<target>` is matched exactly
  **or as a prefix** (`iictl revert-all pack:foo` for one pack, `iictl revert-all
  pack:` for all). This is the single shared mechanism; domains must NOT
  re-implement ledger replay.
- **User-edit guard** — before stripping a fenced `custom/*.lua` block, revert-all
  diffs the current body against the pristine `/etc/skel` copy; a divergence is
  **kept** and warned unless `--force` is given (PROPOSAL §17 edge case).

### iictl chooser contract + `iictl-tui` renderer (#47)

The "choose-then-tweak" UX is a framework primitive with **two deliberately
decoupled halves** (PROPOSAL §11): the **contract** (a declarative option spec
every domain emits) and the **renderer** (one fancy ratatui binary that draws
it). The point of the split: the **engine stays bash** (pack, revert-all,
ledger, mutators, every `set` verb, the whole install-chroot path) and the
renderer is **swappable** — the *same* spec also drives the Quickshell Control
Center (#14), so CLI/GUI parity is structural, not hand-maintained.

- **The contract (`iictl <verb> --spec`, JSON).** A domain advertises its
  configurable surface as a tiny spec with **EXACTLY three control types** (the
  anti-clutter ceiling — domains *cannot* build a maze):
  - `choice` — single pick from `options[]`; `apply` argv (`%v` = chosen value).
  - `list` — multi add/remove over inline `options[]` **or** a dynamic
    `candidates` argv resolved per `source` (`%s`, the source-driven shells case,
    owned by #48); `apply_add`/`apply_remove` argv (`%v`).
  - `toggle` — boolean; `apply_on`/`apply_off` argv.

  Every `apply*`/`candidates` is an **`iictl` argv array** the renderer runs
  verbatim with `%v`/`%s` substituted — so the renderer mutates nothing; each
  change flows through the domain's bash verb → the ledger. A domain also carries
  a `#spec: <verb><TAB><title>` header (the discovery shape mirrors `#help:`);
  `validate.sh` couples advertise↔answer so the `iictl tweak` listing never lies.

- **The renderer (`iictl-tui`).** A Rust/ratatui binary
  (`overlay/aur-pkgbuilds/iictl-tui/crate/`): `iictl-tui <domain>` runs `iictl
  <domain> --spec`, draws it (styled panels, mouse + keys, Material-You colours
  read **read-only** from the rice's `colors.json` with a static fallback), and
  applies picks by running the `apply*` argv via `std::process`. Progressive
  disclosure + a one-level tweak ceiling + explicit done/cancel are enforced by
  the renderer, not by each domain. `iictl tweak <domain>` (a thin bash drop-in)
  execs it; bare `iictl tweak` lists `#spec:` domains.

- **Build path (the one compiled component in an otherwise plain-shell layer).**
  Shipped as a **local PKGBUILD** in `overlay/aur-pkgbuilds/iictl-tui/`
  (`makedepends=('cargo')`, builds the vendored crate). prebuild compiles it into
  `[ii-extra]`; it is in `packages/base.list`, so mkarchiso pacstraps it into the
  squashfs. It therefore **survives install with NO `ii-verify` exemption** — it
  is a real `/usr/bin` package, not a file under the purged `/usr/local/lib/ii`.
  `pacman -Rns iictl-tui` + `iictl revert-all` ⇒ vanilla. `validate.sh`'s
  `step "iictl-tui chooser contract (#47)"` lints the PKGBUILD/baked-package, the
  tweak bridge (execs the renderer, mutates nothing), the spec schema (sample +
  the live `iictl pack --spec` reference emitter), the single-picker guard (no
  domain opens a second interactive picker), and the advertise↔answer coupling.

### Multi-source list manager — source-resolver drop-ins (#48)

The reusable engine behind #47's `list` control when its candidates come from
several *ecosystems* (the first is zsh plugins: antidote bundles, Oh My Zsh
plugins, raw git repos — "including but not limited to ohmyzsh"). The point of
the split from #47: each domain picks items from multiple sources **without
re-implementing source fetching**, and the source set is **extensible by
drop-in** — adding an ecosystem is one file, no renderer edit (the `iictl.d/`
model applied to sources). #15's shell layer *consumes* this for its plugin
picker; it owns only the shell *choice* + the `.zshrc`/antidote *loading* wiring.

- **The substrate (`scripts/runtime-lib/sources.sh`).** A sourced lib on the
  survive-path (kept by `ii-verify`, like `ledger.sh`/`mutator.sh`). It provides:
  - **manifest line helpers** — `ii_manifest_add`/`_remove`/`_current`/`_has`
    over a caller-supplied plain-text manifest (one entry per line; `#` comments
    ignored; exact-line matching, idempotent, atomic-rewrite remove). The shared
    default add/remove/current every source falls through to.
  - **drop-in source discovery + dispatch** — `ii_sources_list` enumerates the
    `sources.d/<name>` basenames (no hardcoded list); `_ii_source_call <name>
    <op>` sources the resolver once and dispatches `candidates|add|remove|current`
    to `ii_source_<name>_<op>`, falling through to the manifest helper when the
    resolver does not override add/remove/current.
  - **baseline reversibility recorder** — `ii_manifest_baseline <manifest>`
    records ONE ledger row the first time a manifest is touched (idempotent,
    keyed on the manifest path as the ledger target), BEFORE the first mutation,
    reusing an EXISTING revert-all inverse (no new ledger kind): a **`skel-shadow`**
    row (snapshot the curated baseline to a sibling backup; revert `cp -a`s it
    back) when the manifest pre-exists, else a **`file`** row owning the manifest
    path (revert `rm`s it ⇒ vanilla; the antidote load line no-ops when absent).

- **The source-resolver drop-in contract (`sources.d/<name>`).** ONE **sourced**
  bash fragment (never executed — like a pack hook, so mkarchiso's +x mode-strip
  can't disarm it) defining at minimum:
  - `ii_source_<name>_candidates [<manifest>]` — print, one per line, candidate
    ENTRIES, each line the EXACT manifest line to add. The value is
    self-describing because #47's renderer applies `apply_add`/`apply_remove` with
    `%v` only (it does NOT pass the source `%s` to the apply argv — see
    `app.rs`), so encoding the source into the value keeps add/remove
    source-agnostic (the same "value == thing to act on" shape as `pack`).
  - optionally `ii_source_<name>_{add,remove,current} <manifest> [<entry>]` —
    override only when the entry needs special handling (e.g. `git` normalizes a
    clone URL to `user/repo` before the shared append). Omit them to inherit the
    manifest helpers.

- **The domain verb (`scripts/runtime-lib/iictl.d/plugins`).** The first consumer.
  Manifest: `~/.config/zsh/ii-plugins.txt` — an **ii-namespaced, UNOWNED/excluded
  slot** (the `.config/zsh` dir is not an upstream-shipped path and is not in
  upstream's `rsync --delete` set; the SAME file #15 has `antidote load` read).
  `iictl plugins {list,sources,candidates,add,remove}`; `--spec` emits a
  source-driven `list` control (`sources` = the resolvers, Tab-cycled in
  `iictl-tui`; `candidates` = `iictl plugins candidates %s`; `current` = the
  manifest entries; `apply_add`/`apply_remove` = `iictl plugins {add,remove} %v`);
  `iictl tweak plugins` renders it. `--revert` delegates to `iictl revert-all
  <manifest>` (the single replay owner — domains must NOT re-implement replay).
  Every add/remove is preceded by `ii_manifest_baseline`, so a revert restores
  the curated baseline; deleting the manifest ⇒ vanilla. `validate.sh`'s
  `step "iictl plugins multi-source list manager (#48)"` enforces: the manifest
  target is ii-owned/unowned (skel-shadow invariant — not an upstream/rsync-delete
  path), the resolvers are drop-in (no hardcoded source `case`), recording routes
  through the shared baseline recorder (no bespoke `ledger_record` in the verb;
  reuses `skel-shadow`/`file` inverses), each resolver `bash -n`s + defines
  `ii_source_<name>_candidates`, and the live `iictl plugins --spec` is a valid
  source-driven list spec.

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
  **Precondition (BUILD-06):** the official-vs-AUR split trusts the *host*
  pacman sync db. `docked`/CI runs `pacman -Sy`; bare local builds may not, and
  an empty/stale db makes every official name miss `-Si` and get silently
  misrouted to the AUR/prebuild path. So the step opens with `_assert_sync_db`,
  which `die`s loudly (telling you to `sudo pacman -Sy`) when any official
  repo's `*.db` is missing/empty or older than `II_SYNCDB_MAX_AGE_DAYS` (default
  14; `[ii-extra]` is excluded — it is built locally, never `-Sy`'d). `validate.sh`
  guards that this assertion exists and precedes the first `pacman -Si`.
- **45-optional-packs** — stages `packages/optional/*.list` (+ `*.meta` and
  `<pack>.d/post-add|post-remove` hook fragments) as **text** into
  `/usr/share/illogical-impulse/optional/`. Only the few-KB lists ride in the
  image; `iictl pack` installs the members online on demand (never baked).
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

### docked builds

`containers/builder.Dockerfile` is the canonical environment; `just docked`
runs prepare → validate → prebuild (as the `builder` user, uid-remapped to
the host user so build/ stays host-owned — iron rule 2 holds inside docker
too) → mkiso (root), with the AUR cache persisted in the `ii-extra-cache`
docker volume. `--privileged` is required (mkarchiso needs loop devices).
The release CI (`release.yml`) uses this same image.

## 5. The justfile

Recipes are deliberately one-liners delegating to scripts — CI calls the
same surface, so behavior can't fork between local and automated builds.
Adding a recipe: script first (sourcing common.sh), recipe second, README
table third. Current surface: `setup prepare prebuild build validate
update vm smoke preview nspawn test-revert clean nuke assets image docked`.

## 6. Validation & testing

- `just validate` — static, no root, fast. Structure: profiledef →
  packages.x86_64 criticals → airootfs structure → identity → Calamares
  (branding, instance mapping, unpackfs sourcefs, bootloader) → batteries
  spot-check + nvidia manifests → mkinitcpio hooks → repo conf → script
  syntax (`bash -n` everything) → **additive/reversibility lint** (Pillar 6).
- **`tools/lint-additive.sh`** — the mechanical Iron-Law enforcer, sourced by
  `validate.sh` as the `step "additive/reversibility lint"`. Owns the four
  structural Pillar-6 checks: (0) `skel-upstream` precondition hard-fail (no
  false pass on an empty basis), (1) skel-shadow collision — no
  `overlay/skel-distro` file or `skel-distro.fetch` dest may land on an
  upstream-owned path (exact shadow of a `skel-upstream` file, or inside an
  `install_dir__sync` dir; the empty `custom/*.lua` slots + the OOB
  `kitty-theme.conf` STATE seed are exempt), (4) `packages/optional/*.list`
  validity + no double-bake into `packages.x86_64`, (6) PII guard
  (`[user]` block, build-host git identity, baked email). The other three
  Pillar-6 checks (fence, `iictl.d` hygiene, `ii-verify` survival) already live
  inline in their own `validate.sh` steps — see the file header for the map.
- `just vm [--disk|--installed|--fresh-disk]` — the manual boot gate; `just
  smoke` is the headless QEMU colour-probe the release CI runs.
- `.github/workflows/validate.yml` — prepare+validate in an
  `archlinux:base-devel` container on push/PR.

## 7. Update & release flow

`just update` fast-forwards the dots submodule (dirty-tree guarded);
`just update --check` evaluates the bump policy (`min_days_between_releases`,
`require_new_commits` in distro.toml) and exits 0/1 — CI-consumable. After
a bump: `just prepare && just validate`, build, VM-test, commit the pin.

**Update channels + the stable pin (#27).** The installed system has a channel,
a single line in the distro-owned `/etc/illogical-impulse/release` stamp:
`CHANNEL=stable` (default) or `edge`. `iictl update` (stable) checks out the
recorded `DOTS_COMMIT` exactly before driving upstream's `./setup`; `--channel
edge` tracks upstream HEAD and persists `CHANNEL=edge` (reversible — switching
back restores the pin). **The stable pin lives in the release stamp**:
`70-assets.sh` stamps `DOTS_COMMIT = git -C $DOTS rev-parse --short HEAD`, so a
`just update` submodule bump automatically advances the next build's pin — the
recorded pin can never rot away from the submodule, and `validate.sh` asserts
the two agree at build time (the anti-rot guard). Channel switches are
ledger-recorded for `iictl revert-all`. Companion verbs: `iictl migrate` runs
baked one-time `migrations/NNNN-*.sh` (idempotent via an applied high-water
mark), `iictl docs` prints the baked offline quickstart, and `iictl config
export/import` serialises the ledger + choices to a portable bundle (tar/awk,
no jq) replayed through the per-verb engines — the net-new reproducible-setup
edge over an irreproducible `curl|bash`.

Implemented in `.github/workflows/release.yml`: daily cron runs the
`--check` gate → bumps the pin (committed by github-actions[bot]) → `just
docked` (AUR cache via actions/cache on `.ii-cache` through II_CACHE_DIR) →
`just smoke` (headless QEMU boot; QMP screendumps must reach ≥16 distinct
colors — text-fallback regressions fail) → rsync ISO + SHA256SUMS to
SourceForge (frs.sourceforge.net, SF_SSH_KEY secret, project
illogical-impulse-iso) → GitHub release with notes + checksums.
workflow_dispatch forces a release from the current pin.

## 8. Easy extensions (designed-for)

- **Distro-level fetch.list** — *shipped*: `30-skel.sh` reads an
  `overlay/skel-distro.fetch` list (same `<dest> <url> <rev>` format as the
  profile `fetch.list`) and layers it before the profile, for distro-owned
  pinned vendoring.
- **More editions** — a second profile is just a directory; nothing else
  to wire (not yet built).

## 9. Bug archaeology

Every design oddity earns its keep — the full list lives in
[CLAUDE.md](../CLAUDE.md) §"Historic bugs encoded in design choices".
Read it before "simplifying" anything in chroot.sh, the Calamares configs,
or the runtime scripts.
