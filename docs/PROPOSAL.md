# Illogical Impulse → A Quickshell-Native Developer Distro
### A comprehensive, additive, reversible proposal to out-build Omarchy

---

## 1. Executive Summary

end4ISO already ships something Omarchy structurally cannot: a **live QML desktop shell** (Quickshell) instead of a static bar (Waybar + Walker/rofi). It also already ships the three load-bearing primitives that make a "developer distro" tractable without forking upstream — the **NVIDIA offline stash** (an on-ISO flat pacman repo consumed post-install), the **profile `fetch.list`** (pinned git vendoring into skel), and the **standalone welcome card** (a `qs -p` config with zero imports from upstream's `quickshell/ii` tree, autostarted via the sanctioned empty `hypr/custom/execs.lua` slot).

This proposal generalizes those three proofs into **one reusable substrate** and then layers a full developer experience on top: a multi-shell layer, an editor chooser, dev-toolchain packs, a fleet of optional Quickshell widgets, a theming/flavor engine, and — the centerpiece — a **graphical `iictl` Control Center** that is the GUI front end for every reversible tweak.

Every addition obeys **The Iron Law**: it is *additive* and *reversible*, built ON TOP of what the build grabs from upstream. Delete our files, run one command (`iictl revert-all`), and the vanilla upstream rice returns unchanged. We never edit `upstream/` (read-only submodule) and never edit an upstream-owned file in skel — we layer beside them in the seams upstream guarantees it leaves free.

**What changed after the audits.** Two independent audits verified these claims against the repo and the dots submodule. Their findings are folded in throughout, but five reshape the plan and must be read first:

1. **`ii-verify` deletes `/usr/local/lib/ii` on clean install** (`scripts/runtime/ii-verify`, the purge after the FAIL check: `rm -rf /usr/local/lib/ii /usr/share/ii-python-wheels`). Any `iictl.d/` plugin dir or `ledger.sh` placed there is **wiped at install time**. This is a **blocker** that must be fixed before any plugin/ledger work begins. → Framework Pillar 3.
2. **`~/.config/zshrc.d` is upstream `rsync --delete` territory** — files we drop there are wiped on `iictl update`. The themed-zsh story must live in a **home-root `.zshrc` that sources `zshrc.d` read-only**, never in it. → Shell domain (fixed).
3. **Seven domains each independently re-invented `iictl pack`, `packages/optional`, `skel-distro.fetch`, and the ledger.** This collides. The **Additive & Reversible Framework is promoted to a prerequisite milestone** that ships *first*; every feature domain consumes its primitives. → Section 4.
4. **The ISO is already ~5.8 GB**, over GitHub's 2 GiB asset cap (hence SourceForge). Domains casually bake overlapping tools. A single **bake-vs-fetch budget governor** is now a hard gate — bake only small+universal, fetch everything heavy online. → Section 4 Pillar 7 + Section 12.
5. **`terminal`/`codeEditor` defaults live in upstream-owned `hypr/hyprland/variables.lua`**, *not* the empty `custom/variables.lua` slot. The override still works (custom wins, sourced by `keybinds.lua`), so the mechanism is sound — **the rationale wording was wrong**, and the fix is to write a *fallback list* (chosen term first), not a single hardcoded binary, so uninstalling it degrades gracefully via upstream's `launch_first_available.sh`.

The deliverable is a layered roadmap: **Framework first (Phase A/B)**, then the Control Center and high-leverage features, then breadth, with everything heavy deferred to offered packs.

---

## 2. Vision & Positioning vs Omarchy

Omarchy's appeal is *glue*: a one-chord menu hub, a one-key webapp installer, a 19-theme switcher with a git-URL marketplace, curated app/dev-runtime installers, a unified `omarchy` CLI with tab-completion, and a stable/edge update model. Its weaknesses are equally structural: the config surface is a Walker `--dmenu` text list; its themes are frozen hand-authored color sets that don't recolor per-wallpaper; its installers are effectively one-way; and it ships *separate edition images* (gaming, creator) because it bakes everything.

We match every Omarchy convenience and then leapfrog on the axes only a QML shell enables:

| Axis | Omarchy | end4ISO (proposed) |
|---|---|---|
| **Config surface** | Walker `--dmenu` text list | A **graphical Quickshell Control Center** — Material You rail navigation, search, live previews, inline toggles |
| **Theming** | 19 frozen color sets, all-or-nothing | **Material-You-from-anything**: drop any wallpaper/photo or seed a flavor (Catppuccin/Nord/Gruvbox…) → the *whole* rice recolors through upstream's own matugen pipeline, live |
| **Reversibility** | one-way install scripts | a **state ledger + `iictl revert-all`** — every change is recorded and undoable to byte-for-byte vanilla |
| **Editions** | separate gaming/creator images | **one lean image** + offered, composable, reversible packs (installed online on demand) |
| **Webapps** | plain Chromium `--app` windows | **accent-aware** webapps (per-app window class themed/auto-placed via `custom/rules.lua`) |
| **Already at parity (do NOT re-build)** | cheatsheet (Super+K) | upstream **Super+/ cheatsheet** ships; OCR/capture, clipboard (Super+V), Material You all already upstream |

**Honest concessions** (copy, don't pretend to beat): Omarchy's hosted 49-chapter manual, its breadth of *deliberately* curated themes, and its mature gaming setup. We ship a focused *offline* docs subset, a small curated flavor/wallpaper pack for cold-start polish, and the gaming stack *wholesale as an optional pack*.

**The thesis:** *Everything Omarchy gives you in a dmenu, we give you in a graphical Control Center — and the look adapts to you instead of you picking from a fixed list.* This stems from one fact no Omarchy iteration on Waybar+Walker can match: **the shell is programmable QML**.

---

## 3. The seams we build into (verified)

Every proposal targets one of these upstream-guaranteed seams. The reversibility of the whole plan rests on respecting their classes.

| Seam | Class | Behaviour | Used for |
|---|---|---|---|
| `~/.config/hypr/custom/{env,execs,general,rules,variables}.lua` + `custom/scripts/` | **`install_dir__ignore_existing`** (preserved forever) | upstream ships them as 1-byte stubs, never overwrites | autostart hooks, keybinds, window rules, default-app override, recolor hooks |
| `~/.config/nvim`, `~/.bashrc`, `~/.config/git`, `~/.config/{btop,bat,fastfetch,zellij,…}`, `~/.config/illogical-impulse/`, `~/.config/illogical-impulse-theming/`, `~/Projects` | **unowned** (upstream ships nothing) | no collision possible | baked dev defaults, themed tool configs, nvim, scaffolds |
| `~/.config/fish/conf.d/ii-*.fish` | **excluded from upstream sync** (`30-skel.sh` `--exclude=conf.d`) | fish auto-loads it; ours are the only files there | fish tool/theming enrichment |
| `~/.config/quickshell/ii/**`, `~/.config/matugen/**`, `~/.config/fish/config.fish`, `~/.config/zshrc.d/**`, `~/.config/hypr/hyprland/**`, `~/.config/fontconfig/**`, `~/.config/starship.toml`, `hyprlock.conf` | **`install_dir__sync` (`rsync --delete`)** ⚠️ | **anything we add here is wiped on `iictl update`** | **READ-ONLY** — observe via `FileView`, source read-only, never write |
| `config.json`, `~/.local/state/quickshell/user/generated/colors.json`, `…/generated/terminal/sequences.txt`, `…/generated/material_colors.scss` | **upstream-owned runtime STATE** ⚠️ | generated/owned by the rice | **READ-ONLY** — `FileView`-watch for theming; never seed defaults; record prior value in ledger for revert |
| `packages/optional/*.list` | **reserved, NOT baked** (`40-packages.sh`) | designed-for | curated name-lists installed **online on demand** by `iictl pack` (only the list ships, never the packages) |
| `iictl` (`/usr/local/bin/iictl`) | **survives install** (named-exempt from purge) | the post-install config surface | every user-selectable feature |

> **Auditor correction folded in:** the `40-packages.sh` header comment still says optional lists "become Calamares software-selection groups (phase 2)." Calamares selection was **built, hit friction, and deliberately removed**. The comment must be updated to: *"installed on demand from the internet by `iictl pack` (official repos + AUR)."*

> **New seam class to document (auditor addition):** upstream-owned **runtime STATE** (`config.json`, `colors.json`, `sequences.txt`) is distinct from the sync-deleted *config* dirs. The distro **never pre-seeds** it; features only call upstream public entry points (`switchwall.sh`, `qs ipc`) and record prior values in the ledger. BLUEPRINT must document this class.

---

## 4. THE ADDITIVE & REVERSIBLE FRAMEWORK (the backbone — ship this first)

This is non-negotiable and frames everything below. Both audits converged on the same structural conclusion: at least seven feature domains independently proposed their own pack engine, their own `skel-distro.fetch` wiring, and their own ledger — *with no shared owner*. That overlap **will collide** (multiple `pack)` dispatch cases, multiple `30-skel.sh` fetch loops, multiple staging steps). Therefore the framework is a **prerequisite milestone**; every feature proposal carries an implicit *"requires framework v1."*

The framework is seven pillars.

### Pillar 0 (BLOCKER, do this before anything) — Make `iictl`'s lib survive install

`ii-verify` runs `rm -rf /usr/local/lib/ii` on a clean install. Any `iictl.d/` plugin dir, `ledger.sh`, or runtime helper placed there is deleted. **Fix first:**

- Narrow `ii-verify`'s purge to remove only the named ISO-helper *files* (the `for b in …` list it already enumerates), **not** `rm -rf /usr/local/lib/ii`.
- Keep `iictl.d/` and `ledger.sh` under a survive-path; purge only ISO-only helpers (`session-offline.sh`, chroot-only files) by name.
- Add a `validate.sh` assertion (mirroring the existing "iictl survives" check) that `iictl.d/` + `ledger.sh` are NOT in the purge list.

No plugin or ledger work may start before this lands.

### Pillar 1 — `packages/optional/<pack>.list` (curated bundles installed online on demand)

One pack = one curated bundle (`lang-rust.list`, `gaming.list`, `virt.list`…) — a plain list of package **names** (a few KB of text). The list rides in the squashfs as text only; **the packages themselves are never staged into the image.** `iictl pack install <name>` installs the members on demand over the network: official-repo members via `pacman -S`, AUR members via paru (presence-checked, bootstrap-or-error). Every install is ledger-recorded so `iictl pack remove` is an exact, offline-safe `pacman -Rns`. `#meta:conflicts` is enforced before any pacman runs.

> **Why online, not stashed (decision):** an earlier draft staged each pack's full dependency closure into an on-ISO flat repo for offline post-install. That bakes heavy software the user may never want into **every ISO and every installed system** — `gaming` + `virt` + `lang-*` alone would add multiple GB to an image already over GitHub's cap. Optional software is **fetched online when the user asks for it**; the ISO carries only the curated name-list. `[ii-extra]` is build-host-only and does not survive install, so the install path is the public mirrors + AUR, never `[ii-extra]`. (The **NVIDIA driver stash** stays an on-ISO repo — drivers are tiny, hardware-conditional, and must work at first boot before a network may exist; that is a bounded exception, **not** a pattern for software packs.)

### Pillar 2 — `overlay/skel-distro.fetch` (distro-level pinned vendoring)

The BLUEPRINT-named "trivial extension." A new file in the exact `<dest-rel-to-skel> <git-url> <rev>` format as profile `fetch.list`. `30-skel.sh` gains a ~15-line block (run *after* the skel-distro rsync at the `/etc/skel = skel-upstream + skel-distro` step, *before* the profile layer, so profiles still win) reusing the existing `.fetch-cache/` loop. Destinations are **distro-owned paths only** (e.g. `.config/nvim`, `.antidote`) — lint forbids upstream-owned paths.

### Pillar 3 — `iictl.d/` drop-in subcommand architecture

Refactor iictl's hard-coded dispatch: built-ins (`update`/`venv`/`doctor`/`welcome`/`version`) stay inline; the current `*) die` branch becomes a resolver that execs `/usr/local/lib/ii/iictl.d/<cmd>` with a sourced common header (colors, `ok`/`bad`/`die`, `RELEASE_FILE`, ledger helpers). Each domain ships its verb as **one file** (`iictl.d/shell`, `iictl.d/pack`, `iictl.d/theme`, `iictl.d/revert-all`…) — zero merge conflicts in the core. Help is harvested from each plugin's header comment (which also auto-generates man pages — see §11 additions). Depends on Pillar 0.

### Pillar 4 — The install/state ledger

A per-user, append-only ledger at `$XDG_STATE_HOME/illogical-impulse/` (the namespace the welcome card already uses via `welcome_shown`). It records every reversible action with its inverse: target, package set, owned paths, restore hint. A shared `ledger.sh` (`ledger_record`, `ledger_owned_paths`, `ledger_query`, replay helpers) is sourced by iictl, every plugin, and `ii-post-install`.

> **Decision (audit):** ledger format is **plain TSV**, not JSONL — keeps `revert-all` dependency-free (parse with `awk`/`cut`, already present) and avoids baking `jq` just for undo bookkeeping.

The ledger **is** the machine-checkable manifest behind "delete our stuff and vanilla returns." Lint guarantees no upstream-owned path ever enters it.

### Pillar 5 — `iictl revert-all` + per-feature `--revert`

Replays the ledger in reverse: removes owned paths, `pacman -Rns` the recorded sets (offline-safe — removal needs no network), strips distro-appended blocks from `custom/*.lua` by **sentinel fence**, restores any shadowed skel-upstream copy, then re-runs `iictl doctor` to confirm clean state. `--dry-run` prints the plan.

- **Sentinel-fence convention (mandatory, framework-owned):** every block the distro writes into a sanctioned slot is wrapped in `-- >>> illogical-impulse <name>` / `-- <<< illogical-impulse <name>`. **The existing welcome-card `execs.lua` block must be retrofitted to this fence now.** All writers/removers go through one shared helper; `validate.sh` asserts every distro-written `custom/*.lua` block is fenced; `doctor` warns on user-mangled fences.
- **Two-tier (decision):** `revert-all` undoes *iictl-time choices* (the common case); `revert-all --deep` also peels install-time distro setup (groups, sockets, fetched skel) for the purist "pure upstream" guarantee.

### Pillar 6 — Reversibility lint gate (`validate.sh` + `tools/lint-additive.sh`)

Mechanical enforcement of the Iron Law, run by `just validate`:

1. No `overlay/skel-distro` or `skel-distro.fetch` path collides with an upstream-owned path — computed by diffing against `build/airootfs/etc/skel-upstream` (**allowlist** only the empty `custom/*.lua` slots).
2. Every distro write into a `custom/*.lua` slot is sentinel-fenced.
3. Every `iictl.d` plugin is executable, has a shebang, passes `bash -n`, and declares a one-line help header.
4. Every `packages/optional/*.list` is a valid manifest (parseable names + `#meta`) and none of its members are already baked into `packages.x86_64`.
5. `ii-verify` does NOT purge `iictl.d` / `ledger.sh`.
6. **No baked file contains a `[user]` block or identity string** (PII guard — §11).

> **Audit fix:** the lint reads `build/airootfs/etc/skel-upstream`, which exists only after `30-skel.sh`. It must **hard-fail if that dir is missing or sparse** (mirror `30-skel.sh`'s own `>= 100 files` guard), or derive the upstream set from the dots submodule directly — otherwise the check silently passes when run early.

### Pillar 7 — The bake / fetch budget governor (HARD gate)

Two tiers, enforced:

- **BAKED** — in the squashfs, always installed. *Only small + universal things* (`goodies.list`/`base.list`).
- **FETCHED-ONLINE** — installed on demand over the network by iictl (official repos via `pacman`, AUR via paru). **Everything heavy/opinionated**: language runtimes, gaming, virt, security, AUR shells/tools, nvim distros + plugins, and the bulky long tail (wallpaper packs, model files, editor extensions). Only the curated few-KB name-list (`packages/optional/*.list`) rides in the squashfs — never the dependency closure.

Rule: anything **> ~150 MB installed footprint** that isn't universal is **FETCHED-ONLINE, never BAKED** — and never stashed into the image. A soft squashfs budget; `validate.sh` **warns when a heavy/non-universal package appears in `goodies.list`**. Per-pack metadata declares `#meta:conflicts` (and `#meta:type flatpak` for flatpak packs). The one sanctioned on-ISO repo is the **NVIDIA driver stash** (a bounded hardware exception — see Pillar 1). See §12.

### Framework — shared mutator library (auditor addition)

A single `ledger.sh`-adjacent helper providing **idempotent**, **reversible**, **ledger-recording** primitives that *every* system-touching pack must use (rather than re-implementing):

- `ii_service_enable` / `ii_service_disable` (records inverse)
- `ii_group_add` (mirrors the docker-group pattern in `ii-post-install`)
- `ii_lua_block_write` / `ii_lua_block_remove` (sentinel-fenced)
- `ii_chsh` — registers the shell in `/etc/shells` idempotently *first* (AUR shells like fizsh/nushell are not there by default → `chsh` fails or PAM-prompts otherwise), then `chsh`, recording the prior shell
- `ii_conflicts_check` — enforces declared `#meta:conflicts` *before* `pacman` runs (the laptop power-tool mutual exclusion proves the need)

> **Reversibility guarantees (framework):** Nothing is installed by default beyond `goodies.list`. Every iictl action is ledger-recorded with its inverse. `iictl revert-all` (or `--deep`) returns to vanilla. The lint *mechanically* forbids writing upstream-owned paths and unfenced `custom/*.lua` blocks at build time — so a future contributor physically cannot merge a non-reversible feature.

---

## 5. Domain: Shell Ecosystem & Plugin Management

**Owner of the shell layer.** Per the audits, *four* domains independently shipped bash/zsh wiring with conflicting layouts. This domain is the **single owner**; onboarding/dev-toolchain/parity *consume* it. Canonical layout, settled once:

- `~/.bashrc` — **complete, self-contained** file (Arch ships a skel `.bashrc`, so ours is a full replacement, not an append-loader; guarded by a file-exists test on the sequences file) → sources `~/.config/ii/*.sh`.
- `~/.zshrc` (home-root) — sources `~/.config/zshrc.d/*.zsh` **read-only** (upstream's snippets), sources the generated terminal sequences, loads antidote from `~/.config/zsh/ii-plugins.txt` (guarded), inits starship/zoxide/atuin/carapace/direnv.
- `~/.config/fish/conf.d/ii-*.fish` — the excluded-from-sync slot; tool/theming/alias enrichment.
- `mise`/`zoxide`/`atuin`/`carapace` activation lines live **only** in those canonical files, never in upstream's `config.fish`/`zshrc.d`.

> **Audit blocker fixed:** the original "ship `.zshrc` into `zshrc.d/`" idea was wrong — `zshrc.d` is `rsync --delete`'d. The themed-zsh experience lives in a **home-root `.zshrc`** that *sources* `zshrc.d` read-only. Upstream's snippets keep working; our file is never touched by `iictl update`.

**Narrative.** Upstream configures fish + starship and ships `zshrc.d/` snippets (no `.zshrc`), themes fish and zsh via the generated color sequences, and leaves **bash unconfigured**. We add a distro shell layer entirely in the free seams, make a one-command `iictl shell` chooser the user-facing surface, and ensure **Material You theming survives whichever shell you pick** (for nushell, which can't `cat` raw escapes, iictl *translates* `sequences.txt` → a nu theme).

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| `iictl shell` chooser | `list\|set <fish\|zsh\|bash\|fizsh\|nushell>\|status\|prompt\|plugins` — installs pkg if needed, `ii_chsh`, ensures themed init exists | offered | `iictl.d/shell`; templates in `/usr/share/illogical-impulse/shells/`; `ii_chsh` registers `/etc/shells` first | (uses installed shells) | M | must |
| Themed bash | self-contained `~/.bashrc` sourcing sequences + starship + tool stack | baked | `overlay/skel-distro/.bashrc` (unowned slot) | — | S | must |
| Themed zsh | home-root `.zshrc`/`.zshenv` sourcing `zshrc.d` read-only + antidote + tool stack | baked | `overlay/skel-distro/.zshrc` + `.zshenv` (unowned) | zsh, zsh-completions | S | must |
| antidote + curated bundle | `~/.config/zsh/ii-plugins.txt` (autosuggestions, syntax-highlighting, completions, fzf-tab); `.zshrc` runs `antidote load` (guarded) | baked | unowned `.config/zsh`; antidote via `skel-distro.fetch` or AUR pack | zsh-antidote (AUR) | M | must |
| fish enrichment | `conf.d/ii-{tools,aliases,theme}.fish` (zoxide/atuin/carapace/direnv inits, defensive re-source) | baked | the `--exclude=conf.d` seam | zoxide, atuin, direnv | S | should |
| carapace cross-shell completions | one binary → 1000+ completions in every offered shell, wired in our init files only | baked | `goodies.list` (or `optional/shells.list`); init lines in ii-owned files | carapace-bin (AUR) | S | should |
| Modern CLI stack | zoxide/atuin/direnv/fzf-keys wired per-shell additively | baked | per-shell ii-owned blocks | zoxide, atuin, direnv, fzf | S | should |
| Extra shells | fizsh, nushell, themed bash; nushell theme via `sequences.txt`→nu translator in iictl | offered | `optional/shells.list`; configs in unowned slots | nushell, fizsh-git (AUR) | L | should |
| Plugin picker | `iictl shell plugins` fzf/skim TUI editing `ii-plugins.txt`; QML GUI later | offered | `iictl.d/shell`; optional standalone QML picker | (fzf/skim baked) | M | could |
| Prompt selector | starship default everywhere; `iictl shell prompt` offers oh-my-posh via a `~/.config/illogical-impulse/ii-prompt` selector | mixed | selector read by all per-shell inits | oh-my-posh (AUR) | M | could |

**Reversibility guarantees.** `ii_chsh` records the prior shell; `iictl shell set fish` (or revert) restores upstream's default. Every dropped file is ii-namespaced in an unowned/excluded slot; the antidote load line no-ops when the manifest is absent. Upstream's `config.fish`/`zshrc.d` are only *sourced*, never patched.

**Decisions:** default login shell stays **fish** (upstream's tested, themed default); zsh framework is **antidote** (fastest simple manager, static cache, plain-text editable, already prototyped); bake `zoxide+direnv+carapace+starship`, **offer atuin** (its sync/daemon is opinionated); opt-in shells install **online** (official-repo shells via pacman, AUR ones like fizsh/nushell via paru); plugin **TUI now, QML later**.

---

## 6. Domain: Editor Ecosystem — Neovim distros + IDE packs

**Narrative.** Upstream ships **zero** `~/.config/nvim` (verified), and its `codeEditor` keybind already probes `zed/cursor/code/nvim/micro/emacs` via `launch_first_available.sh` — so adding an editor *self-wires* the rice's editor key with no config edit. `~/.config/nvim` is wholly unowned: the chooser can own it with zero collision.

> **Audit resolution (cross-domain conflict):** the editor domain proposed *baking* LazyVim into skel; other domains argued plain nvim. **Resolution: ship plain nvim with an empty `~/.config/nvim` as vanilla, and offer distros via `iictl nvim`** with backup-on-conflict + an ownership stamp. This keeps the Iron Law trivially true (no nvim config to revert by default) and is the more honest "batteries included, choices reversible" posture. The chooser refuses to clobber a user's own config without `--force`.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| `iictl nvim` chooser | `set <lazyvim\|astronvim\|nvchad\|kickstart\|plain\|restore\|status>`; timestamped backup of `~/.config/nvim` + `~/.local/share/nvim`, pinned clone, `.git` strip, headless bootstrap, `.ii-distro` stamp | offered | `iictl.d/nvim`; writes only user-owned `~/.config/nvim`, `~/.local/{share,state}/nvim` | git, neovim (baked) | M | must |
| Theme-matched default (opt-in via chooser) | one-shot Material You recolor through a distro-owned matugen feeder | offered | see theming domain feeder | matugen (upstream dep) | M | should |
| Material You bridge | matugen template emitting `~/.config/nvim/lua/ii-material.lua`; each distro's `ii-theme.lua` reads it | mixed | distro-owned matugen config via `--config` + `--import-json` (NEVER edit upstream `config.toml`) | matugen | L | should |
| nvim plugins on first boot | `lazy.nvim` fetches the chosen distro's plugins **online** on first `nvim` launch (its native behaviour); per-distro `lazy-lock.json` pins versions for reproducibility | online | `iictl nvim` clones the pinned distro at set-time; plugins fetch on first run — nothing nvim rides in the ISO | git, neovim, tree-sitter-cli | M | should |
| IDE packs | `iictl edit <web\|rust\|python\|go\|devops>` installs VS Code/Cursor extensions from `edit-packs/*.txt`; `iictl edit theme` merges (jq) Material You into `~/.config/Code/User`, `--restore` removes only added keys | offered | `iictl.d/edit`; writes only user IDE config | code, cursor-bin (baked), jq | M | could |
| zed/helix/micro/emacs | `optional/editors.list`, installed on demand; auto-wired by upstream's editor keybind | optional-pack | not baked; `iictl edit install` → pacman | zed, helix, micro, emacs | S | could |
| Welcome-card surface | "Choose your editor" button → `iictl nvim` | baked | edit only the distro-owned welcome `shell.qml` | quickshell | S | could |

> **Audit fixes:** (a) the matugen bridge depends on matugen honoring a config include/`--config`; **confirm during impl**, and if not supported drive it via `iictl nvim theme --config <distro-config>` so upstream's `config.toml` stays byte-identical. (b) **Default to one-shot** recolor (`iictl nvim theme`), not a live watcher (no daemon, fully reversible). (c) **Do NOT offer LunarVim** (effectively unmaintained; the author moved to AstroNvim). (d) Material You for IDEs must **merge with jq**, never overwrite `settings.json`, and `--restore` removes only the keys it added.

**Reversibility guarantees.** `iictl nvim restore` or `rm -rf ~/.config/nvim ~/.local/share/nvim` returns to bare neovim. The chosen distro is cloned at set-time and its plugins fetch online; everything lands in the user-owned nvim dirs. The matugen bridge never touches upstream's `config.toml`. IDE theme `--restore` is jq-surgical.

**Decisions:** baked default = **plain nvim** (chooser offers all four); install = **clone the chosen distro online at set-time**, lazy.nvim fetches plugins on first run, LSP/extensions on demand (nothing nvim rides in the ISO); ship `iictl nvim` first, `iictl edit` as a follow-up (two clear verbs).

---

## 7. Domain: Developer Toolchains, Languages, Version Managers, Containers

**Narrative.** Bake a thin universal baseline; make every heavy/opinionated choice an offered, pacman-reversible pack on the framework's `iictl pack` engine. We out-develop Omarchy on three axes: mise-managed runtimes (like theirs) exposed through a Quickshell picker, full pacman reversibility (`iictl pack remove` vs one-way installers), and Quickshell AI-widget tie-ins a static bar can't offer.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| Thin dev baseline | small, official-only, universal CLIs | baked | `# dev baseline` block in `goodies.list` | gh, git-delta, direnv, just, **mise** *(not `jq`/`yq` — upstream PKGBUILD `illogical-impulse-basic` already pulls `jq` + `go-yq`)* | S | must |
| Language packs via mise | `lang-*.list` mix plain pkgs (pacman) + `mise:` directive lines (`mise use -g`); runtimes opt-in | optional-pack | framework pack engine handles both line syntaxes; mise writes user-owned `~/.config/mise` | go, nodejs, pnpm, bun, deno, ruby, zig, jdk-openjdk… | M | must |
| Containers pack | docker/podman/compose stay baked; `containers.list` adds lazydocker/ctop/dive/k9s/kubectl/helm/kind; `--rootless` flag | optional-pack | pack engine; `--rootless` writes user systemd units | + kind (AUR), devcontainer | M | should |
| Baked delta config + dev-cli pack | reversible git `[include]`; `dev-cli.list` = difftastic/gitui/hyperfine/tokei/sd/dust/procs/bottom/xh/httpie/mkcert/pre-commit | mixed | `overlay/skel-distro/.config/git/ii-delta.gitconfig` (unowned) + `[include]`; pack for the rest | git-delta, bat | S | should |
| AI dev pack + Quickshell tie-in | `ai-dev.list`: ollama (+GPU variant via PCI detect), aider/aichat; writes a **user-owned** local-LLM provider config the upstream AI service reads | optional-pack | pack engine; **never** edit `.config/quickshell/ii` | ollama, aider-chat, aichat | L | should |
| Databases / cloud / IaC | `databases.list`, `cloud.list`; services NOT auto-enabled (print enable hint) | optional-pack | pack engine; no systemd units recorded | postgresql, redis, dbeaver, terraform, opentofu, ansible… | M | could |
| Bake distrobox | tiny, podman already baked, transformative | baked | one line in `goodies.list` | distrobox | S | must |

> **Audit fixes:** (a) **paru presence is not guaranteed** — `iictl pack` must *check for paru and bootstrap-or-error*, not assume it; official-repo members install with plain `pacman` (no paru needed), AUR members need paru + network. (b) The AI-widget provider path is **upstream-owned and may change** — verify the documented provider settings (via the Super+I module) before wiring; keep the write to a user-owned file *outside* the synced `quickshell/ii` tree, and if unverifiable, **just install ollama and document manual setup** behind a runtime path check. (c) mise needs `mise activate` in shell rc — that lives in the **shell domain's** ii-owned files, never in upstream `config.fish`. (d) `iictl pack remove` must track exactly what mise installed (record the directive set) to remove cleanly.

**Reversibility guarantees.** Every pack is `pacman -Rns` of a ledger-recorded set. mise toolchains are user-owned and tracked. The AI provider write is a single user-owned file; remove it and the widget falls back to cloud defaults. No baked-image or upstream change beyond removable `goodies.list` lines.

**Decisions:** version manager = **mise** (official extra, Omarchy's choice, zero build cost; reject asdf — AUR-only); AUR packs build **at install via paru** (presence-checked); official-repo packs install directly via pacman; offer via **iictl + Quickshell picker**, *not* Calamares (the "bake everything, ask nothing at install" model stands); keep **rootful docker** baked, rootless as a flag.

---

## 8. Domain: Quickshell Widgets & Desktop Perks

**Narrative.** The welcome card proves the one safe pattern. We generalize it into a *single* widget framework: a shared QML lib (`Theme.qml` `FileView`-watching `generated/colors.json`; `Panel.qml` a `WlrLayershell` base) under `/usr/share/illogical-impulse/widgets/_lib/`, each widget a standalone `qs -p` config, toggled by `iictl widget`. Because Quickshell is reactive GPU QML, these are categorically fancier than Omarchy's Waybar+rofi+swaync.

> **Audit-driven scope cut (major) — upstream already ships most "widgets"; we rebuild NONE of them:** the rice already provides **pomodoro + stopwatch** (`services/TimerService.qml` + `modules/ii/sidebarRight/pomodoro/`), a **scratchpad/notes overlay** (`modules/ii/overlay/notes/NotesContent.qml`), a **todo list** (`sidebarRight/todo/`), a **clipboard manager** (`services/Cliphist.qml` + the launcher's Clipboard prefix), a **color picker** (`hyprpicker -a` in `bar/UtilButtons.qml` + a `colorPicker` quick-toggle), **media controls** (`modules/ii/mediaControls/`), a **resources display** (`bar/ResourcesPopup.qml` + `services/ResourceUsage.qml`), and a full **command palette** (`overview/SearchBar.qml` prefixes: Action/App/Clipboard/Emojis/Math/ShellCommand/WebSearch). What's genuinely *missing* is a reusable framework substrate and a **developer** surface. So v1 ships only: the **widget framework** (`_lib` + `iictl widget`), a baked **dev-dashboard** (git/containers/CI cards — the one widget class upstream lacks), and curated **`actions/*.sh`** that upstream's `LauncherSearch.qml` already auto-loads from `~/.config/illogical-impulse/actions/` via `FolderListModel` (the most surgical seam — it *adds* distro/dev verbs to the existing palette, it does not rebuild it). The only offered extras are a **GPU-stats augmentation** of the existing resources view and **opt-in mpvpaper video wallpaper** — all on the same registry.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| Widget framework | `_lib/{Theme,Panel}.qml`; `iictl widget enable\|disable\|toggle\|list\|autostart`; markers under `~/.local/state/illogical-impulse/widgets/` | baked | `_lib` under widgets dir; `iictl.d/widget`; one **fenced** autostart block in `execs.lua` | quickshell | M | must |
| Command-palette actions | curated `actions/*.sh` (`/devdash-toggle`, `/update-system`, `/doctor`, `/screenshot-region`…) auto-loaded by upstream launcher | mixed | `overlay/skel-distro/.config/illogical-impulse/actions/` (blessed empty extension dir); never edit `LauncherSearch.qml` | — | S | must |
| Dev-dashboard (v1 reference widget) | git/containers/CI cards via Quickshell `Process` — the one widget class upstream lacks | **baked** | widget dir; `devdash.json` config | github-cli, git, docker | L | should |
| GPU-stats augmentation | adds GPU/temps to the **existing** resources view (upstream `ResourcesPopup`/`ResourceUsage` already cover CPU/RAM/swap — do not duplicate those) | offered | widget dir; GPU vendor detected at runtime (nvidia-smi/amdgpu sysfs/intel_gpu_top) | lm_sensors | M | could |
| Video wallpaper | opt-in mpvpaper, feeding upstream's existing `__restore_video_wallpaper.sh` seam | optional-pack | `optional/*.list` | mpvpaper | M | could |
| Fullscreen app dashboard *(#29)* | Plasma-style searchable icon grid + smart categories; `iictl launcher` flips vanilla↔dashboard | offered | standalone `qs -p` app in `/usr/share/illogical-impulse/launcher/` (zero `quickshell/ii` imports); fenced `custom/keybinds.lua` override repoints the launcher key — never edits upstream `overview/` | quickshell | L | should |
| ~~Pomodoro / notes / clipboard UI / color picker / now-playing ticker~~ | **DROPPED — all shipped by upstream** (TimerService, overlay/notes, Cliphist, hyprpicker, mediaControls) | — | — | — | — | — |

> **Audit fixes:** (a) **every** `execs.lua`/`keybinds.lua` write is sentinel-fenced (framework). (b) Widget QML lives under the **system `widgets/` dir**, NOT a `~/.config/quickshell/ii-*` sibling — that sits one typo from the `rsync --delete` tree. (c) `Theme.qml` falls back to a **static palette** if `colors.json` is missing/renamed; `validate.sh` asserts the path exists. (d) **Keybind strategy: a `Super+W` leader submap** (claims exactly one bind to stay deconflicted with upstream's evolving `keybinds.lua`) + the zero-collision `actions/` palette as fallback; reserve direct `Super+<key>` only for the dev-dashboard after auditing upstream binds.

**Reversibility guarantees.** Each widget: `iictl widget disable` (kills `qs`, removes the fenced block + marker) or delete the dir. The `actions/` seam reverts by deleting our scripts (upstream's empty dir returns). Nothing imports from `quickshell/ii`; nothing edits an upstream file.

**Decisions:** **bake framework + dev-dashboard + actions** (pomodoro/notes/clipboard/colorpicker/now-playing are already upstream — not rebuilt), offer the GPU-stats augmentation + video wallpaper; theming via **`FileView`-watch `colors.json`** (never edit matugen `config.toml`, never hardcode); **`Super+W` leader**; GPU-stats bakes only **lm_sensors**, detects GPU at runtime.

---

## 9. Domain: Theming, Ricing & Aesthetics

**Narrative.** Upstream owns Material You end-to-end (`switchwall.sh` → matugen → `applycolor.sh`). We **feed** that pipeline, never fork it. A "flavor" is a *seed* fed through matugen, so Nord/Catppuccin/Gruvbox become *live, wallpaper-harmonized* Material You — not frozen sets.

> **Verified reversibility seam (auditor + this domain):** upstream's own updater treats `~/.config/matugen` (and `quickshell/ii`, `fish`, `hypr/hyprland`) as `rsync --delete`, but `~/.config/hypr/custom/` as `ignore_existing`. **Therefore: never add `[templates.*]` to matugen's `config.toml`** — it's wiped on update. Use a **standalone matugen feeder** invoked with `matugen --config <our-path> --import-json colors.json`, wired through the preserved `custom/` slot.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| `iictl theme` flavor engine | `list\|set <flavor>\|reset\|current\|gui`; drives upstream `switchwall.sh --color HEX` (flavor) / `--color clear` (reset) / `--image PATH` | offered | `iictl.d/theme`; flavors at `/usr/share/illogical-impulse/themes/*.conf` | jq | M | must |
| Static themed defaults | btop/fastfetch/bat/lazygit configs for tools upstream leaves unconfigured (mirrors existing `kitty-theme.conf` OOB pattern) | baked | `overlay/skel-distro/.config/{btop,fastfetch,bat,lazygit}/` — **unowned**, safe from `--delete` | btop, bat, lazygit, fastfetch, starship | M | must |
| Feeder templates for dev tools | bat/delta/lazygit/btop/fzf recolor live | offered | templates in `~/.config/illogical-impulse-theming/` (unowned); recolor hook via preserved `custom/scripts/` + `execs.lua`; **opt-in, off by default** | inotify-tools, git-delta, bat | L | should |
| GTK/Qt/icon/cursor coherence | fill non-color gaps matugen leaves: adw-gtk3 base, Papirus icons, Bibata cursor — set via `gtk-3.0/settings.ini` (NOT the matugen-owned `gtk.css`) | baked | `settings.ini` + `~/.icons/default` (orthogonal to color CSS) | adw-gtk3, papirus-icon-theme, bibata-cursor-theme (AUR) | M | should |
| Curated wallpaper pack | one branded default baked; full pack fetched into `~/Pictures/Wallpapers/showcase/` | offered | `iictl wallpaper`; `pack.list` manifest (url+sha256+rev) | curl, imagemagick | M | should |
| Video wallpaper | supply the batteries for upstream's *existing* mpvpaper path | mixed | `iictl wallpaper video` → `switchwall.sh --image <video>` | ffmpeg, mpvpaper (AUR) | S | could |
| QML theme/flavor picker | standalone swatch grid (welcome-card model) | offered | `theme-picker/shell.qml`; shells out only | quickshell | L | could |
| Login/lock & Plymouth | branded hyprlock overlay (imagery beside matugen colors); **Plymouth opt-in only** | mixed/offered | hyprlock distro overlay sourced via `custom/`; `iictl theme plymouth {enable,disable}` regenerates **both** initramfs presets | plymouth | M–L | could |

> **Audit fixes:** (a) the **live inotify recolor watcher is opt-in, debounced, and reads the FINISHED `colors.json`** (not the mid-write `.scss`) — it risks the exact `applycolor.sh` race CLAUDE.md §6 warns about; static themed fallbacks are baked, the watcher is off by default. (b) **One owner** (theming) provides the recolor hook; the terminal domain *consumes* it (no duplicate watcher). (c) Plymouth's mkinitcpio edit must call `ii-prepare-bootloader` for **both** presets on enable *and* disable; `doctor` flags a hook-without-regeneration. (d) `iictl theme set` must **warn** that a `--color` accent override persists and wins over later wallpaper picks until `theme reset` (`--color clear`); `doctor` surfaces an active override.

**Reversibility guarantees.** `iictl theme reset` = upstream's own `--color clear` → byte-identical to never running it. All theming files live in **new/unowned paths or the preserved `custom/` slot** — `validate.sh` enforces no skel-distro file lands in a sync-deleted dir. We add **no** competing color generator.

**Decisions:** first-boot = **stock wallpaper-derived** (run nothing), discoverable via welcome card; live recolor = **offered** (static baked, watcher opt-in); wallpaper pack = **fetch-only** (ISO size); icons/cursor = **Papirus + Bibata**; Plymouth = **opt-in with guaranteed disable**, never baked.

---

## 10. Domain: Terminal Emulators, Multiplexers & TUI Experience

**Narrative.** Upstream bakes kitty (+ configs for kitty/foot) and ships **no** config for zellij/tmux/fastfetch/btop/bat. The decisive seam: `applycolor.sh` emits a terminal-**agnostic** `sequences.txt` — any terminal whose shell `cat`s it inherits Material You. We bake a small universal TUI layer and offer heavy emulator/mux swaps via `iictl tui`, sharing **one** Material You source so every emulator themes automatically.

> **Audit correction (major, repeated across this + parity domain):** `terminal`/`codeEditor` default-app vars live in **upstream-owned `hypr/hyprland/variables.lua`** (sync-deleted), *not* the empty `custom/variables.lua`. The override slot **is** sourced and wins, so the mechanism is sound — but `iictl tui term` must write a **fallback list with the chosen term first** (mirroring `launch_first_available.sh`), so uninstalling it degrades gracefully instead of breaking `Super+Return`.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| Color-aware bash | `cat` sequences + eza/bat aliases (shell-domain owned) | baked | shell domain's `~/.bashrc` | — | S | must |
| Polished zellij | `config.kdl` + dev `layouts/ii.kdl`, themed via the recolor pipeline | baked | `overlay/skel-distro/.config/zellij/` (unowned) | zellij | M | must |
| Themed fastfetch/btop/bat/onefetch | branded + Material You | baked | unowned config dirs (shared with theming domain — **single owner: theming**) | onefetch (+ baked tools) | M | must |
| ~~Extra-terminal recolor~~ | **DROPPED — upstream already recolors every emulator**: `scripts/colors/applycolor.sh` `apply_anyterm()` broadcasts OSC color escapes to all open PTYs on each theme change, and the shells `cat` `generated/terminal/sequences.txt` at startup. Any emulator inherits Material You for free; a per-emulator renderer is redundant. (Only emulators upstream ships *static* config for differ; ghostty/wezterm still get live OSC.) | — | — | — | — | n/a |
| `iictl tui` chooser | `term <kitty\|ghostty\|wezterm\|alacritty\|foot>` / `mux <zellij\|tmux\|none>` + Quickshell QML card | offered | `iictl.d/tui`; writes the fallback-list `terminal=` line in `custom/variables.lua` | ghostty, wezterm, alacritty, tmux | L | should |
| tmux + tpm vendoring | distro `skel-distro.fetch` pins tpm; themed `.tmux.conf` | optional-pack | framework Pillar 2 | tmux | M | could |
| dev-TUI pack | lazygit theme + zoxide/atuin/lazydocker | optional-pack | `optional/devtui.list`; inits in shell-domain files | zoxide, atuin, lazydocker | M | could |

**Reversibility guarantees.** The recolor is upstream's, so there is nothing of ours to revert there. The zellij config is an unowned-path file (delete it → vanilla). The default-terminal change is one override file writing a fallback list (chosen term first); delete it → upstream `launch_first_available` chain returns. Uninstalling an emulator degrades via the fallback list.

**Decisions:** default emulator = **kitty** as explicit distro default (only baked dep, richest upstream config) via the override; multiplexer = **config-only by default**, auto-start offered via `iictl tui mux zellij`; recolor = **hybrid** (static baked + on-demand re-render + opt-in watch); chooser = **QML card + CLI**, skip Calamares.

---

## 11. Domain: `iictl` Control Center (the centerpiece)

This anchors the roadmap. **ONE flagship standalone Quickshell app** is the GUI front end for every reversible iictl tweak.

> **Audit consolidation:** rather than ~12 separate apps, the Control Center is the **single** standalone Quickshell surface, with internal panes. Onboarding folds in as a pane/button, not a second auto-launching app (see §13).

**Architecture.** `/usr/share/illogical-impulse/control/shell.qml` (welcome-card pragmas: `UseQApplication`, QtQuick + Controls.Basic + Layouts + Quickshell.Io, **zero** `quickshell/ii` imports). A left NavigationRail with cards — Overview, **Packages**, Shell, Editor, Plugins, Dev Packs, Theme & Wallpaper, Perks, **System & Updates** (doctor / update with stable·edge channel selector #27 / driver), Learn — behind a top SearchField and a StackLayout. A `Colors.qml` singleton `FileView`s `generated/colors.json` (read-only) so the app **re-themes itself** when the wallpaper changes — a visible "wow." A single `Ctl.qml` `QtObject` wraps `Process` to call `iictl <verb> --json` and `runInTerminal()` for long actions (the welcome card's proven pattern).

**Built to extend + to feel flawless (first-class, not polish-as-afterthought).** The rail and StackLayout are **generated from a declarative pane registry** (`control/panes.js`) — adding future functionality is a *drop-in pane*: one `panes/<X>.qml` + one registry line, **no shell edits** (the GUI analogue of the `iictl.d/` drop-in CLI model; each domain issue contributes its own pane). Every pane composes a shared, `Colors`-themed **design-system kit** (`control/_ui/`: Card, Button, Toggle, ListRow, SearchField, Spinner, EmptyState, ErrorState, Toast…) so the app is consistent by construction. The **flawless-UX bar** is acceptance-tested: keyboard-first nav (`/` focuses search, arrows/Enter/Esc), a global search that jumps **across** panes, async/non-blocking actions (the UI never freezes on AUR builds or updates — Spinner→Toast), explicit loading/empty/error states everywhere, and animated transitions.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| **State ledger + reversibility engine** | framework Pillar 4/5; every writer appends an idempotent revert recipe | baked | `ledger.sh` + `iictl.d/revert-all` (survives via Pillar 0) | (none; TSV) | M | must |
| **Control Center GUI** | the standalone panel; pane-registry + `_ui/` design system; panes shell out to iictl | baked | `control/` under the welcome dir family; `iictl center` (`qs -p`) | — | L | must |
| **`iictl pkg`** software manager *(#30)* | one-click search/install/remove of any **official-repo + AUR** package; installed/orphans/updates; protected-set guard; a Packages pane + CLI verb | offered | `iictl.d/pkg` over pacman/paru; `control/panes/Packages.qml`; user pkgs are the user's own (NOT in the revert ledger) | (pacman/paru) | L | should |
| Launch surfaces | `.desktop` (System;Settings;), `SUPER+SHIFT+I` (neighbor of rice `Super+I`), welcome-card button | baked | `.desktop` in airootfs; **fenced** block in `custom/keybinds.lua` | fuzzel | S | must |
| `iictl shell/editor/plugins/pack/theme/perks/tweak` | thin verbs the GUI drives (defined in their domains) | offered | `iictl.d/*` | per domain | — | — |
| `iictl tweak` | safe reversible system toggles (sockets, libvirtd, bluetooth, firewalld, snapper rollback, zram, trim) | offered | ii-owned drop-ins (`/etc/sysctl.d/99-ii-*`, override dirs) + ledger inverse | snapper, snap-pac (baked) | M | could |

> **Audit fixes:** (a) the Control Center is **freeform `ApplicationWindow`** first (reuse the welcome-card model), layer-shell variant later. (b) It reads `colors.json` **by path with a static fallback** (treat the path as a watched seam in `just update --check`). (c) Every writer goes through a single `ledger.append_revert()` helper; `validate.sh` asserts every `control` writer references it. (d) Explicit copy distinguishes **"Rice Settings" (Super+I, upstream)** from **"Distro Control Center" (Super+Shift+I, ours)** — the Control Center never exposes rice-internal knobs.

**Reversibility guarantees.** `iictl control revert <feature>` / `revert-all` replays the ledger. `rm -rf /usr/share/illogical-impulse/control` + the `.desktop` + the fenced keybind = the app is gone; the rice referenced nothing of ours.

**Decisions:** default shell stays **fish** (offer switching); window = **freeform `ApplicationWindow`**; packs = **small focused primitives + 2–3 role bundles**; nvim = **offer four, bake none**; keybind = **`SUPER+SHIFT+I`**; theme = **strictly wrap `switchwall.sh`** (no forked color logic).

---

## 12. Domain: Omarchy Parity Matrix & Differentiation

| Feature | Omarchy | end4ISO today | Proposed move |
|---|---|---|---|
| Central menu hub | `SUPER+ALT+SPACE` dmenu | none | **Control Center** + `iictl menu` fuzzel fallback (§11) |
| One-key webapp installer | `chromium --app` + favicon → `.desktop` | none | `iictl webapp add/remove` → **Brave** `--app` `.desktop`; **accent-aware** via `custom/rules.lua` |
| Theme switcher + marketplace | 19 static themes + git URL | Material You from wallpaper, no named-theme | `iictl theme` flavor engine + `theme import <git-url>` (§9) |
| Curated app installer | Install> repo/AUR/dev | bake-all | `iictl install <group>` over `optional/*.list` incl. gaming |
| Dev-runtime installer | Install>Development | rustup+uv | `iictl dev` via baked **mise** (§7) |
| Unified CLI + completion | `omarchy` 3.7 | iictl, no completion | shell completions + grouped help + auto-gen man pages |
| Update channels + migrations | stable/RC/edge + migrations | always HEAD | pinned-**stable** default + `--channel edge` + migrations dir |
| Cheatsheet / capture / clipboard / Material You | yes | **already upstream** (Super+/, Super+Shift+S/X/T/A, Super+V) | **NONE — parity; do not re-build** |

**Three signature wins (lean in):** the **graphical Control Center** vs a dmenu list; **Material-You-from-anything** vs frozen sets; **accent-aware webapps** vs plain Chromium windows. **Honest concessions (copy):** hosted docs (ship a focused offline subset + `iictl docs`), curated-theme breadth (small curated pack), gaming maturity (optional pack, copied wholesale).

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| `iictl webapp` | `add <name> <url> [icon]` / `remove`; icon fetch best-effort + generic fallback; writes `~/.local/share/applications/ii-webapp-<slug>.desktop` | offered | `iictl.d/webapp`; optional accent rules in `custom/rules.lua` | brave-bin (baked) | M | must |
| Shell completions + grouped help | fish/bash/zsh completions; `--version`; man pages auto-generated from `iictl.d` headers at build | baked | completion files in airootfs system dirs | bash-completion | S | must |
| `iictl install` + gaming/creators/etc. | picker over `optional/*.list`; `pkg`/`aur` thin wrappers | optional-pack | framework engine (online install: pacman + paru) | paru + group contents | M | should |
| Update channels + migrations | stable pin in `/etc/illogical-impulse/release`; `iictl migrate` runs `migrations/NNNN-*.sh` | baked | extend `cmd_update`; migrations dir | — | M | could |
| Default-app chooser + offline docs | `iictl defaults` (xdg) ; `iictl docs` offline quickstart | baked | `iictl.d/defaults`/`docs`; docs in airootfs | xdg-utils | S | could |

> **Audit fixes:** (a) **`SUPER+ALT+SPACE`** is currently unbound upstream → safe for the Control Center/menu; still verify against `hypr/hyprland/keybinds.lua` at each dots bump via `update.sh --check`. (b) `iictl theme set` depends on upstream IPC verb names — pin to public verbs and add a `doctor` check that the IPC call exists, **failing soft**. (c) webapp icon fetch (duckduckgo ip3) is external → best-effort with a generic fallback icon. (d) If adopting channels, **wire the stable-pin bump into `just update`** (it already has a `--check` gate) so it can't rot; otherwise keep HEAD-tracking default and offer `--channel stable`.

**Decisions:** hub chord = **`SUPER+ALT+SPACE`** (+ CLI); webapp engine = **Brave** (already baked); theme layer = **medium** (thin manifests + small curated pack, never a competing generator); default channel = **stable/pinned** (opt-in edge); default webapps = **opt-in `iictl webapp seed`**; runtime manager = **mise**.

---

## 13. Domain: Out-of-the-Box Developer Experience & Onboarding

**Narrative.** Upstream ships nothing at home-root (no `.gitconfig`, `.bashrc`, `.ssh`, `.editorconfig`, `~/Projects`), leaving the whole home namespace clobber-free. We add three tiers: tiny universal baked defaults; a guided first-run flow; offered heavy choices.

> **Audit consolidation:** the onboarding flow is **folded into the existing welcome card** as a skippable "Set up your dev environment" button (or a Control Center pane launched on demand) — **not** a second auto-launching Quickshell app. Upstream-welcome → distro-welcome → distro-onboarding would be three first-login interruptions; keep exactly one distro first-run surface.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| `iictl git-identity` | prompts name/email → `~/.config/git/config` (no hardcoded identity); `[include]` → identity-free defaults | offered | `iictl.d/git-identity`; per-user runtime, never skel | git | S | must |
| Baked dev defaults | `ii-defaults.gitconfig` (delta, autosquash, `defaultBranch=main`, **no `[user]`**), `.editorconfig`, `direnvrc`, global gitignore, `~/.ssh/config` skeleton (perms re-applied by chroot/post-install — mkarchiso strips modes) | baked | unowned home-root paths via skel-distro | git-delta, direnv | S | must |
| `iictl keys` | ed25519 SSH + optional GPG signing key; copy-to-clipboard via upstream cliphist; idempotent | offered | creates only `~/.ssh`/`~/.gnupg` | openssh, gnupg | M | should |
| `~/Projects` + `iictl new` | scaffold from `/usr/share/illogical-impulse/templates/{node,python,rust,go,static,devcontainer}/`; safe token substitution (no identity, text-only trees) | mixed | `Projects/.keep` + template tree | git, docker-compose | M | should |
| `iictl dotfiles import` | chezmoi/stow/bare-git, **backup-on-conflict** to `~/.config/ii/dotfile-backup/`, never runs without a URL | offered | `iictl.d/dotfiles` | chezmoi, stow | M | could |
| Dormant systemd-user units | ssh-agent, podman.socket helper — present but **not enabled** | mixed | `~/.config/systemd/user/` (no `.wants` symlink baked) | openssh, direnv, podman | S | could |
| Discoverability | enriched `iictl help` (dev section); point AT upstream Super+/ cheatsheet (do not duplicate); `fastfetch` "try: iictl onboard" nudge | mixed | unowned configs + airootfs | fastfetch | M | could |

> **Audit fixes:** (a) the onboarding marker logic reconciles with `cmd_welcome`'s existing two-stage marker — **one surface**. (b) `~/.ssh/config` perms (0700/0600) must be re-applied by `chroot.sh`/`ii-post-install` (mkarchiso's `cp --no-preserve=mode` strips them). (c) `~/.bashrc` is a **complete self-contained file** guarded by a sequences-file existence test (Arch ships a skel `.bashrc`; an append-loader can't append at build time and risks double-sourcing). (d) the bash sequences `cat` is guarded (degrades gracefully if upstream renames the path). (e) **Global PII rule + lint:** no baked file may contain a `[user]` block or identity string; templates use a safe placeholder scheme, and onboarding detects a pre-existing `user.email` and skips.

**Reversibility guarantees.** Every baked default is a standalone deletable file in an unowned path. `iictl git-identity`/`keys`/`new` write only per-user runtime state. Dotfile import backs up before overwriting. Dormant units do nothing until `systemctl --user enable`.

**Decisions:** default shell = **fish** (+ themed bash + chooser); toolchain = **mise coexists** with rustup/uv; **bake no language runtimes** (mise installs them online during onboarding); API client = **none baked** (`optional/api.list`); nvim = **plain + chooser**; onboarding = **auto-shown once via the welcome card with a one-click skip**; `init.defaultBranch = main`.

---

## 14. Domain: Unconsidered Perks (gaming, multimedia, laptop, security, virt, backup, fonts, printing, bluetooth, flatpak)

All ride the framework's `iictl pack` engine + shared mutator library. Small universals are baked; everything heavy/opinionated/hardware-specific is offered.

| Proposal | What | Delivery | Additive mechanism | Packages | Effort | Priority |
|---|---|---|---|---|---|---|
| Bake small universals | emoji font, bluetooth codecs, printing/scanning | baked | `goodies.list` lines; `cups.socket` added to `ii-post-install`'s existing service loop | noto-fonts-emoji, bluez-utils, cups, cups-pdf, sane, simple-scan *(NOT `ttf-jetbrains-mono-nerd` — upstream `illogical-impulse-fonts-themes` already pulls it)* | S | must |
| Bake distrobox | (also in §7) | baked | `goodies.list` | distrobox | S | must |
| Gaming pack | steam/lutris/heroic/gamemode/mangohud/gamescope/proton-ge; game-mode toggle (standalone Quickshell, **fenced** execs line added only when installed) | optional-pack | `gaming.list` + `gaming.d/post-add` | steam, lutris, gamemode, lib32-*, … | M | should |
| Creative pack | kdenlive/audacity/blender/darktable/krita/handbrake + codecs; DaVinci behind `--with-davinci` | optional-pack | `creative.list` | … + davinci-resolve (AUR) | S | should |
| Laptop pack | power-profiles-daemon (default), brightnessctl, fprintd (PAM via **ii-owned drop-in**, restorable); tlp/auto-cpufreq as **mutually-exclusive** `--power=`; Quickshell power widget | offered | `laptop.list` + hooks; auto-offer if `BAT*` present | power-profiles-daemon, fprintd, … | M | should |
| Security pack | ufw/firewalld, opensnitch, keepassxc, yubikey, sbctl, tailscale, wireguard; services not auto-`up` | optional-pack | `security.list` + ii-owned rulesets | … | M | should |
| Virt pack | libvirt/qemu-full/virt-manager (+groups via mutator); waydroid behind `--with-waydroid` | optional-pack | `virt.list` + hooks | … | M | must (distrobox baked) |
| Backup pack + snapshot boot entry | btrfs-assistant, snapper-rollback, restic/borg; `ii-finish-systemd-boot` writes an **additive** `ii-snapshots.conf` only if root is btrfs | mixed | `backup.list`; additive loader entry | … | M | could |
| Flatpak curation | `iictl pack add flatpak-extras` adds flathub + curated apps; **remote addition recorded in ledger**, `--purge-remote` opt-in on revert | offered | `flatpak-extras.list` (`#meta:type flatpak`) | (flatpak app-ids) | S | could |

> **Audit fixes:** (a) **Drop the gaming multilib auto-enable** — multilib is **already enabled** in the installed `pacman.conf`; just install `lib32-*` against it. (b) All system-level edits (PAM, mkinitcpio, sockets, groups) go through the **shared mutator library** with ledger-recorded inverses — never in-place vendor-file edits. (c) Power tools conflict on one `.service`; the engine enforces `#meta:conflicts` *before* pacman. (d) Pack widgets live in skel-distro but their launching `execs.lua` line is **added/removed by the hook**, never pre-baked (else non-pack users get dead launchers). (e) Confirm the **installer default filesystem is btrfs** (gates snapper/snap-pac value and the snapshot boot entry) — check `overlay/calamares/modules/partition.conf`.

**Reversibility guarantees.** Every pack = `iictl pack remove` (ledger-recorded `pacman -Rns` + post-remove hook disabling services, removing groups, deleting ii-owned drop-ins and fenced blocks). Baked universals are deletable `goodies.list` lines.

**Decisions:** packs live in **iictl** (not revived Calamares); laptop power default = **power-profiles-daemon**; **bake distrobox + one nerd font + emoji**, keep btrfs-assistant in the backup pack; gaming **installs `lib32-*` against already-enabled multilib**; AUR pack members build at runtime via paru (documented network requirement).

---

## 15. ACTIONS TO GET RESULTS — phased roadmap

Concrete, repo-level, ordered. **The framework and the Control Center anchor everything.**

### Phase A — Framework foundation + quick wins (unblocks all)
1. **Fix `ii-verify` (BLOCKER):** narrow purge to named ISO-helper files; keep `iictl.d/`+`ledger.sh`; add the `validate.sh` survive-assertion.
2. Refactor `scripts/runtime/iictl`: replace `*) die` with the `iictl.d/` resolver + sourced common header; build help from plugin headers.
3. Create `overlay/airootfs/usr/local/lib/ii/{ledger.sh (TSV), mutator.sh}` and `iictl.d/` (`pack`, `revert-all` initial). Wire `ledger_record` into `ii-post-install`.
4. Adopt the **sentinel-fence** convention; **retrofit the existing welcome `execs.lua` block** to it.
5. Create `packages/optional/` as curated **name-lists** (text only, NOT baked into `packages.x86_64` and NOT stashed into the image); `iictl pack` installs members online on demand.
6. Add `overlay/skel-distro.fetch` + the ~15-line loop in `30-skel.sh` (before the profile layer).
7. `validate.sh` + `tools/lint-additive.sh`: skel-shadow check (allowlist `custom/*.lua`), fence check, plugin lint, optional-list validity check (parses + not baked), no-PII check, ii-verify survival check; **hard-fail if `skel-upstream` is missing/sparse**. Wire the skel-shadow check into `update.sh --check`.
8. Fix the stale `40-packages.sh` Calamares comment.
9. **Quick wins (small, universal, baked):** `# dev baseline` block in `goodies.list` (gh, git-delta, direnv, just, mise — **not** jq/yq/jetbrains-nerd, already upstream PKGBUILD depends) + distrobox + emoji font + cups/bluez stack (+ `cups.socket` in the post-install loop); themed bash (`~/.bashrc`); shell completions + grouped `iictl help`.
10. Document the bake/fetch tiers + the upstream-owned-STATE seam class in BLUEPRINT; update CLAUDE.md §5 "Where to edit."

### Phase B — The centerpiece + shell/theme/editor cores
11. **Control Center:** `control/shell.qml` + `Colors.qml` + `Ctl.qml` + panes; `iictl center`/`menu`; `.desktop`; fenced `SUPER+SHIFT+I` and `SUPER+ALT+SPACE` binds; welcome-card button.
12. **Shell layer** (single owner): `iictl.d/shell`, home-root `.zshrc`/`.zshenv`, `~/.config/zsh/ii-plugins.txt`, fish `conf.d/ii-*.fish`, `optional/shells.list`, `ii_chsh`/`/etc/shells` handling.
13. **Theme engine:** `iictl.d/theme` over `switchwall.sh`; flavor `.conf`s; static themed defaults (btop/fastfetch/bat/lazygit); the **opt-in** debounced recolor hook reading finished `colors.json`.
14. **Editor chooser:** `iictl.d/nvim` (plain default + four distros, backup-on-conflict, `.ii-distro` stamp); distros cloned **online** at set-time, lazy.nvim fetches plugins on first run.
15. **Smoke tests:** extend `vm.sh` (or new `scripts/smoke.sh`) — headless boot + `iictl pack install/remove` round-trip, `revert-all` idempotency, `qs -p` load check per standalone config, doctor golden path.

### Phase C — Dev breadth + widgets + parity glue
16. Language/container/dev-cli/AI packs (`lang-*`, `containers`, `dev-cli`, `ai-dev`); `iictl pack` paru-presence check + online install (official via pacman, AUR via paru).
17. Widget framework (`_lib` + `iictl.d/widget`) + **dev-dashboard** + `actions/*.sh` palette; `Super+W` leader. (No pomodoro/notes/clipboard/colorpicker widgets — upstream ships those.)
18. `iictl webapp` (Brave `--app`, accent rules); `iictl install` group picker + gaming pack.
19. Onboarding folded into the welcome card; `iictl git-identity`/`keys`/`new` + baked dev defaults; `~/Projects` + templates.
20. Terminal/TUI: zellij config + dev layout, `iictl tui` chooser writing the fallback-list `terminal=`. (No per-emulator recolor — upstream's `applycolor.sh` already themes every emulator via OSC broadcast.)

### Phase D — Later / polish / showcase
21. Remaining offered extras (GPU-stats augmentation, video wallpaper) behind `iictl widget enable`. (dev-dashboard is now baked in Phase C; scratchpad/clipboard/colorpicker/ticker are dropped as upstream-provided.)
22. Optional packs: creative, laptop, security, virt, backup (+ snapshot boot entry), flatpak curation; GTK/icon/cursor coherence; Material You bridges (nvim/IDE/extra-terminals).
23. Update channels + migrations (pin bump wired into `just update`); `iictl docs` + auto-generated man pages; QML theme/tui/devpacks pickers; Plymouth opt-in.
24. **New domains the audits flagged as missing** (§16 additions): data-science pack, security-hardening posture, accessibility variants, audio/screencast tooling, `iictl config export/import`.

---

## 16. CONSOLIDATED DECISION REGISTER

Deduped across all domains. **★ = pivotal** — these six become the user quiz.

| Decision | Options | Recommendation |
|---|---|---|
| **★ Default login shell** | fish / zsh+antidote / ask once | **Keep fish** (upstream's themed, tested default); make zsh/bash/fizsh/nushell a one-command `iictl shell` opt-in. Surface the chooser in the welcome card. |
| **★ Default nvim config** | plain (chooser only) / bake LazyVim | **Plain nvim, empty `~/.config/nvim`**; offer four distros via `iictl nvim` with backup-on-conflict. Keeps the Iron Law trivially true; resolves the cross-domain conflict. |
| **★ Where user-selectable software lives** | iictl packs / revive Calamares selection / both | **iictl packs only.** Calamares selection was built, hit friction, and removed; iictl survives install and is reversible. |
| **★ AUR pack install path** | paru at runtime / ship `[ii-extra]` into squashfs / official-only / stash | **Online via pacman + paru:** official-repo packs install directly with `pacman`; AUR via paru (presence-checked, bootstrap-or-error). `[ii-extra]` is build-host-only — never shipped into the squashfs. Optional software is fetched when asked for, not pre-staged. |
| **★ Default dots update channel** | stable/pinned / edge (HEAD) / prompt | **Stable/pinned default, `--channel edge` opt-in** — *only if* the pin bump is wired into `just update`; else keep HEAD-tracking and offer `--channel stable`. |
| **★ ISO-size governance** | per-domain ad-hoc / one budget governor | **Adopt Pillar 7 as a hard gate:** bake only small+universal; **FETCH everything heavy online** (never bake or stash it); `validate.sh` warns on heavy packages in `goodies.list`. |
| Ledger format | JSONL (+jq) / TSV | **TSV** — dependency-free `revert-all`. |
| Version manager | mise / asdf / none | **Bake mise** (official extra), runtimes opt-in; keep rustup+uv. |
| zsh plugin framework | antidote / zinit / z4h / oh-my-zsh | **antidote** (fastest simple, static cache, plain-text editable, already prototyped). |
| Modern CLI: baked vs offered | bake all / bake small + offer atuin / offer all | **Bake zoxide+direnv+carapace+starship, offer atuin.** |
| Default terminal emulator | upstream chain / kitty / ghostty | **kitty** as explicit default (only baked dep, richest config) via the override fallback list. |
| Baked multiplexer behavior | config-only / auto-start / toggle | **Config-only default**, auto-start offered via `iictl tui mux`. |
| Material You for widgets/tools | `FileView`-watch `colors.json` / edit matugen `config.toml` / hardcode | **`FileView`-watch `colors.json`** (read-only, reactive, zero coupling). Never edit matugen config. |
| Live recolor vs on-demand | live watcher / on-demand / hybrid | **Hybrid:** static baked + on-demand + **opt-in** debounced watcher reading finished `colors.json`. |
| Widget keybind strategy | per-key / `Super+W` leader / palette-only | **`Super+W` leader submap + `actions/` palette fallback.** |
| Widgets baked vs offered | framework+dev-dashboard+actions / + GPU-stats / framework only | **Framework + dev-dashboard + actions baked; rest offered. Pomodoro/notes/clipboard/colorpicker/now-playing NOT built — upstream ships them.** |
| Onboarding surface | fold into welcome card / separate auto-launch app | **Fold into welcome card** (one first-run surface, skippable). |
| Plymouth | opt-in via iictl (both presets) / don't offer / experimental | **Opt-in with guaranteed disable + both-preset regen**, never baked. |
| Gaming multilib | auto-enable+revert / install lib32 against enabled / no touch | **Install `lib32-*` against already-enabled multilib** (drop the toggle). |
| Laptop power tool | ppd / tlp / auto-cpufreq / `--power=` | **power-profiles-daemon default**, tlp/auto-cpufreq as mutually-exclusive `--power=`. |
| First-boot flavor | stock wallpaper-derived / pre-seed a signature accent | **Stock wallpaper-derived** (Iron Law max), discoverable via welcome card. |
| Wallpaper pack | fetch-only / bake tiny starter / bake gallery | **Fetch-only** + the single branded baked default. |
| Theme aggressiveness | thin wrap / medium (wrap + curated pack) / thick fixed sets | **Medium** — thin manifest layer + small curated pack; never a competing generator. |
| Webapp browser | Brave / Chromium / user default | **Brave `--app`** (already baked). |
| Default webapps | opt-in seed / auto-seed / none | **Opt-in `iictl webapp seed`.** |
| `revert-all` depth | choices only / everything / two-tier | **Two-tier:** default undoes choices, `--deep` peels install-time setup. |
| iictl.d discovery dir | system-only / system+user | **System-only now**, user dir later if requested. |
| Control Center window | freeform `ApplicationWindow` / layer-shell | **Freeform first** (reuse welcome-card model). |
| Pack granularity | small per-language / large role packs / both | **Small primitives + 2–3 role bundles.** |

---

## 17. RISKS & OPEN QUESTIONS

**Verified blockers / high-risk wiring**
- **`ii-verify` purge** deletes `/usr/local/lib/ii` — *the* highest-risk step; the plugin/ledger architecture silently fails until Pillar 0 lands and the survival lint guards it.
- **`[ii-extra]` does not survive install** — any "install later" feature fetches from the public mirrors + AUR over the network at iictl-time; `[ii-extra]` is build-host-only and is never shipped into the squashfs. (Optional software therefore needs a network at install-time — an accepted trade for not bloating the image.)
- **paru may be absent** if its fail-soft build failed during ISO creation — `iictl pack` must check/bootstrap, and a `doctor`/`validate.sh` check should confirm paru landed in the squashfs.

**Structural**
- **Overlap collision** if domains ship their own pack/fetch/ledger — mitigated by shipping the framework first as the single owner (Section 4).
- **ISO size** (~5.8 GB, over GitHub's cap) — every bake re-checked against Pillar 7; heavy/optional software is **FETCHED-ONLINE**, never staged into the image, so it adds nothing to the squashfs (no per-pack stashes, hence no de-dup problem).

**Reversibility edge cases**
- System-level edits (PAM, mkinitcpio, `/etc/shells`, sockets, groups) are where "delete = vanilla" is hardest — all routed through the shared mutator with ledger inverses; **drop the redundant gaming multilib toggle**.
- Sentinel-fence stripping is regex-based; revert must diff/warn before removing a fence whose body the user edited.
- The reversibility lint must hard-fail when `skel-upstream` is sparse (else it silently passes).

**Upstream coupling (degrade gracefully)**
- Generated-file paths (`generated/colors.json`, `generated/terminal/sequences.txt`, `generated/material_colors.scss`) and IPC verb names are upstream-internal — every consumer needs a static fallback + a `doctor`/`just update --check` watch on the path.
- A future upstream that starts shipping `.zshrc`/`.bashrc`/`config.json` defaults could collide — the skel-shadow lint at submodule-bump time is the guard.
- The live recolor watcher risks the documented `applycolor.sh` race → opt-in, debounced, reads finished output.

**Open questions for the maintainer**
1. **Is the Calamares installer default filesystem btrfs?** (gates snapper/snap-pac value + the snapshot boot entry — check `partition.conf`.)
2. **Verify the AI service's local-LLM provider config path** before wiring ollama (may have moved; keep the write outside the synced tree or document manual setup).
3. **Confirm matugen honors `--config`/`--import-json` include semantics** (the nvim/extra-terminal feeder bridges depend on it; fall back to the `iictl --config` wrapper otherwise).
4. Do you want the **stable channel** maintenance obligation (pin-bump wired into `just update`), or stay HEAD-tracking with stable as opt-in?

**Net-new domains the audits flagged as uncovered** (recommend Phase D scoping): a SETTINGS-PERSISTENCE/MIGRATION contract for `config.json`; a SECURITY-HARDENING/update posture (+ explicit "no telemetry" statement); a first-class **data-science/Jupyter/ML pack** (CUDA/ROCm-aware via the PCI-detect); **audio/screencast** tooling (PipeWire pro-audio profile, OBS presets, asciinema/vhs) to *show* the polish; **accessibility** (high-contrast/large-text Material You variants, orca, reduced-motion for the animated widgets); **conflict-detection** as a first-class pack-engine feature; `iictl config export/import` (reproduce a setup — the natural ledger companion and a concrete edge over Omarchy's irreproducible curl|bash); a unified **fail-soft/offline UX** standard for every post-install action.

---

## 18. ISO-SIZE BUDGET (closing note)

The image is already ~5.8 GB — over GitHub's 2 GiB release-asset cap (it ships via SourceForge). This single fact governs every "bake" decision and is why **Pillar 7 is a hard gate, not advice**:

- **BAKE** only small + universal: the dev baseline (gh/git-delta/direnv/just/mise — *not* jq/yq/jetbrains-nerd, already upstream PKGBUILD depends), distrobox, emoji font, cups/bluez/sane stack, themed shell/tool configs (config text is KB), the Control Center + welcome QML, `iictl.d` + ledger. Total net add should be a few hundred MB at most.
- **FETCH-ONLINE** everything else — every heavy/opinionated stack *and* the bulky long tail: language runtimes, gaming, virt, security, databases, AUR shells/tools, nvim distros + plugins, wallpaper packs, LSP servers, editor extensions, AI models, DaVinci/waydroid. The user installs them on demand over the network (`iictl pack`/`iictl pkg`: official repos via `pacman`, AUR via paru). Only the curated few-KB name-list rides in the squashfs — **nothing's dependency closure is staged into the image.** `[ii-extra]` is build-host-only and is never shipped.
- **The only enforcement point** that remains is the bake guard: `validate.sh` warns when a heavy/non-universal package lands in `goodies.list`. With nothing heavy baked or stashed, there are no per-pack closures to de-dup and no runaway-growth risk.

The discipline is what lets the distro be genuinely *batteries-included* while staying distributable: universal batteries baked, every heavy choice one reversible command away.

**Relevant code paths:** `/home/elessar/Projects/end4ISO/scripts/runtime/iictl` (the `*) die` branch to refactor; help heredoc), `/home/elessar/Projects/end4ISO/scripts/runtime/ii-verify` (the `rm -rf /usr/local/lib/ii` purge to narrow), `/home/elessar/Projects/end4ISO/scripts/prepare.d/30-skel.sh` (the skel layer cake + `--exclude=conf.d` + `/etc/skel = skel-upstream + skel-distro` insertion point), `/home/elessar/Projects/end4ISO/scripts/prepare.d/40-packages.sh` (the stale Calamares comment + the official/AUR classifier to reuse), `/home/elessar/Projects/end4ISO/scripts/chroot.sh` (the NVIDIA driver stash — the one sanctioned on-ISO repo; optional software is NOT stashed), `/home/elessar/Projects/end4ISO/scripts/validate.sh` (new lint section), `/home/elessar/Projects/end4ISO/overlay/airootfs/usr/share/illogical-impulse/welcome/` (the standalone-Quickshell model to clone), `/home/elessar/Projects/end4ISO/packages/{base,goodies,installer,nvidia}.list` (+ new `packages/optional/`).