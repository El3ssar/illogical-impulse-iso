# Illogical Impulse migrations

Omarchy-style one-time schema/setting migrations, baked into the live + installed
system at `/usr/share/illogical-impulse/migrations/` (distro-owned — a sibling of
the iictl survive-path, untouched by `ii-verify`'s `/usr/local/lib/ii` purge).

`iictl migrate` runs each `NNNN-name.sh` here **exactly once**, in `NNNN` sort
order. The highest-applied number is the idempotency high-water mark, recorded
per-user in `$XDG_STATE_HOME/illogical-impulse/migrations.applied`; a migration
whose `NNNN` is ≤ the mark is skipped. `iictl migrate --list` shows applied vs
pending; `iictl migrate --dry-run` previews without applying.

## Convention

- **Filename:** `NNNN-short-description.sh` — `NNNN` is a zero-padded integer
  (e.g. `0001-…`, `0002-…`); the leading digits are the only thing that matters
  for ordering and the applied marker. Pick the next free number.
- **Idempotent + reversible:** a migration may re-run if a prior attempt failed
  before the mark advanced, so make each step safe to repeat. Any system change
  must go through the shared **mutator** helpers (`ii_service_enable`,
  `ii_group_add`, `ii_lua_block_write`, …) so it lands in the ledger and `iictl
  revert-all` can undo it — never hand-roll an `rm`/`sed`/`sed -i` against
  upstream-owned files.
- **Sourced, not exec'd:** `iictl migrate` `source`s each script, so the mutator
  and `ledger_*` helpers are already in scope. Do **not** re-`source`
  `iictl-common.sh` (the runner already did). Just call the helpers.
- **Never touch upstream paths:** migrations operate only on distro-owned and
  user-owned state. `~/.config/{quickshell/ii,hypr/hyprland,matugen,zshrc.d}`
  stay read-only — upstream's `./setup` owns those.
- **Failure:** a non-zero exit aborts before the mark advances, so the migration
  retries on the next `iictl migrate` rather than being silently skipped.

## Example

A no-op migration (the convention demonstrator):

```sh
#!/usr/bin/env bash
# 0001-noop.sh — example migration. Does nothing; demonstrates the contract.
# Real migrations call the shared mutators (ledger-recorded, reversible).
ok "noop migration: nothing to do"
```

The shipped `0001-noop.sh` is exactly this baseline. Real migrations are added
here (numbered `0002-…` and up) as upstream changes warrant them.
