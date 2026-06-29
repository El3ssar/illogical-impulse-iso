# Illogical Impulse — offline quickstart

A small, no-network reference for the distro CLI. The full keybind cheatsheet is
in the rice itself: press **Super + /**.

## iictl — the distro CLI

`iictl <verb>`. Run `iictl help` for the live list (built-ins + installed
plugins). The verbs you reach for first:

| verb | what it does |
|---|---|
| `iictl version` | build version, dots commit (the stable pin), and channel |
| `iictl update` | update the rice via upstream's own `./setup` (see channels) |
| `iictl doctor` | health checks: venv, greetd, boot artifacts, pacman db |
| `iictl welcome` | the distro welcome card (also: bare `iictl`) |
| `iictl venv` | rebuild the Quickshell Python venv |
| `iictl migrate` | run pending one-time schema/setting migrations |
| `iictl docs` | print this quickstart offline |
| `iictl config` | export/import your whole reversible setup |
| `iictl revert-all` | reverse every distro change back to vanilla upstream |

(Other verbs — `pack`, `tweak`, `about`, … — appear in `iictl help` when present.)

## Update channels

Updates flow through end-4's own `./setup` — the distro never patches the rice.
The only choice is *which* commit `./setup` runs against:

- **stable** (default): pins to the recorded `DOTS_COMMIT` baked into
  `/etc/illogical-impulse/release` — the exact, release-vetted dots commit this
  image shipped with. `iictl update` checks out that commit.
- **edge**: tracks upstream `HEAD` (the latest dots, unvetted).

```sh
iictl update                    # update on the current channel (stable by default)
iictl update --channel edge     # switch to edge and update to upstream HEAD
iictl update --channel stable   # switch back to the pinned commit (reversible)
iictl update --system           # also upgrade repo + AUR packages first
```

The channel is a single line in the distro-owned release stamp; switching is
fully reversible. The stable pin advances only when the distro cuts a new
release (the submodule bump is wired into `just update`).

## Migrations

`iictl migrate` runs distro-shipped one-time migrations from
`/usr/share/illogical-impulse/migrations/` (each `NNNN-name.sh` runs once, in
order). `iictl migrate --list` shows applied vs pending; `iictl migrate
--dry-run` previews. The applied high-water mark lives in
`$XDG_STATE_HOME/illogical-impulse/migrations.applied`.

## Portable setup — config export/import

Because every iictl action is ledger-recorded with its inverse, your whole
reversible setup is portable:

```sh
iictl config export ~/my-setup.tar.gz     # bundle the ledger + your choices
# … on another fresh install …
iictl config import ~/my-setup.tar.gz      # replay it (records new ledger rows)
iictl config import ~/my-setup.tar.gz -n   # dry-run: show what would replay
```

Imported actions are themselves recorded, so `iictl revert-all` on the target
peels them back too.

## Reverting everything

`iictl revert-all` reverse-replays the ledger to restore vanilla upstream:

```sh
iictl revert-all --dry-run   # show the plan, change nothing
iictl revert-all             # undo iictl-time user choices
iictl revert-all --deep      # also peel install-time distro setup
```

## More

- Keybinds: **Super + /** in the live session.
- Online docs and source: see `/etc/os-release` `HOME_URL` / `DOCUMENTATION_URL`.
