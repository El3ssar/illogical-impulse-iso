# AGENTS.md — how autonomous agents work this repo

This project is built **one issue per session**. Each agent session grabs a
single GitHub issue, does the work on its own branch, and opens a PR. The
maintainer bakes a full ISO, boots it, manually verifies the feature, and
merges. This file is the contract that keeps parallel sessions from
colliding. **Read it fully before touching anything.**

> Repo: `El3ssar/illogical-impulse-iso` · Issues + PRs via the `gh` CLI.

---

## 0. Required reading (in order, every session)

1. **`AGENTS.md`** (this file) — the workflow contract.
2. **`docs/PROPOSAL.md`** — the full design. Every issue references a `§`
   section; read it.
3. **`CLAUDE.md`** — the project map **and the "Historic bugs encoded in
   design choices" section.** Do not "simplify" those away.
4. **`docs/BLUEPRINT.md`** — pipeline stage contracts and iron rules.
5. The specific files your issue names.

---

## 1. The Iron Law (non-negotiable)

Everything is **additive** and **reversible**, layered *on top of* what the
build pulls from upstream. If our additions are deleted (and `iictl
revert-all` is run), the **vanilla upstream experience returns unchanged.**

- **Never edit `upstream/`** — it is a read-only submodule.
- **Never write an upstream-owned path.** Upstream `rsync --delete` territory
  (`~/.config/quickshell/ii`, `~/.config/zshrc.d`, `~/.config/matugen`,
  `~/.config/fish/config.fish`, `~/.config/hypr/hyprland`, …) is **read-only**
  — observe via `FileView`/source read-only, never add files there.
- **Use the sanctioned seams** (see `docs/PROPOSAL.md` §3): the empty
  `~/.config/hypr/custom/*.lua` slots (writes must be **sentinel-fenced**),
  `~/.config/fish/conf.d/ii-*.fish`, unowned home-root paths, the standalone
  Quickshell pattern (the welcome card), `packages/optional/*.list`,
  `overlay/skel-distro.fetch`, and `iictl.d/` subcommands.
- **Record reversible actions in the ledger** so `iictl revert-all` can undo
  them.
- **Respect identity hygiene:** no baked file may contain a `[user]` block or
  any name/email (the lint enforces this).

A change that cannot be cleanly reverted is a bug, not a feature.

---

## 2. Find work

```sh
# Available, unblocked issues, highest priority first:
gh issue list --label "status:available" --state open
```

Pick an issue whose **`Blocked by:`** list (in the body) is **fully closed**.
If an issue is labelled `blocked` or its blockers are still open, skip it —
its dependencies must merge first. If the maintainer told you a specific
issue number, use that (still run the claim protocol below).

---

## 2a. The bug / correctness lane

Not every issue is a feature. Correctness work — a shipped behaviour that is
wrong, a regression, a broken guard, a security finding — rides its own lane,
marked with the **`bug`** label (description: *"Something isn't working"*).
Triage rule:

- **`bug`** — a defect in already-merged behaviour: it does the wrong thing,
  breaks reversibility, regresses a `validate.sh` guard, or is a security
  finding. Use it instead of (or alongside) `enhancement` when the work is
  *fixing* rather than *adding*. Repo-audit P0/P1 findings file as `bug`.
- **`enhancement`** — net-new capability or polish; the default for feature
  issues.

A `bug` issue follows the same claim → branch → PR flow as any other, with two
extra expectations:

- **Branch prefix `fix/<slug>`** (features use `feat/<slug>`), so the branch
  name alone says whether a PR fixes or adds.
- **Every fixed bug-class becomes a `validate.sh` (or `tools/lint-additive.sh`)
  check** — the project immune system documented in `CLAUDE.md` §"Historic bugs
  encoded in design choices". A bug PR that doesn't add the guard against its
  own recurrence is not done. Priority and `status:available`/`blocked` labels
  work exactly as for features.

(There is no separate `type:bug` label — reuse the single `bug` label above.)

---

## 3. Claim it (collision avoidance — do this *before* writing code)

```sh
N=<issue-number>

# 1. Re-check it is still free (race guard):
gh issue view "$N" --json labels,assignees,title

# 2. If it still has status:available and no assignee, claim atomically:
gh issue edit "$N" --add-label "status:claimed" --remove-label "status:available"
gh issue edit "$N" --add-assignee "@me"
gh issue comment "$N" --body "🤖 Claimed by an agent session ($(date -u +%FT%TZ)). Branch: feat/<slug>."

# 3. Re-read it one more time. If someone else now holds it, BACK OFF and
#    pick another. Last-writer-wins on the label is not enough — the comment
#    + assignee + a re-read is the tiebreaker. If two claims race, the
#    earlier comment timestamp wins; the later session releases.
```

If you cannot claim cleanly, choose a different issue. **Never work an issue
you did not successfully claim.**

---

## 4. Branch

```sh
git switch main && git pull --ff-only
git switch -c feat/<slug>        # <slug> is in the issue title prefix / body
```

- **Never commit to `main`.** One branch per issue.
- Keep the branch focused on the single issue. Spotted something else? Note
  it in a comment or a new issue; don't scope-creep.

---

## 5. Do the work

- Implement exactly what the issue's **Implementation steps** describe, using
  the **sanctioned seams**.
- Follow the existing code idioms (see `CLAUDE.md` §Conventions and
  `docs/BLUEPRINT.md` §Iron rules): `ii-`/`ii_` prefixes, one concern per
  `prepare.d/NN-*.sh`, `var=$((var+1))` never `((var++))`, identity only from
  `distro.toml`.
- **Every fixed bug-class becomes a `validate.sh` check** (project immune
  system). New seams get a lint rule in `tools/lint-additive.sh`.
- Run the automated gate locally and make it green:

```sh
just prepare && just validate
bash -n scripts/**/*.sh   # syntax-check anything you touched
```

---

## 6. Open the PR

```sh
git push -u origin feat/<slug>
gh pr create \
  --base main \
  --title "<same prefix as the issue, imperative>" \
  --body "Closes #$N

## What
<short description>

## How it stays additive & reversible
<which seam; how revert restores vanilla>

## How to test
<EXACT maintainer steps: build, boot, what to click/run, and how to
 confirm reverting restores vanilla — copy/refine the issue's Test plan>

## Checklist
- [ ] \`just prepare && just validate\` green
- [ ] Touches no upstream-owned path; writes to custom/*.lua are sentinel-fenced
- [ ] Reversible (ledger entry / deletable files); revert restores vanilla
- [ ] Added/extended a validate.sh or lint-additive.sh check where relevant
- [ ] Docs updated (CLAUDE.md / BLUEPRINT.md) if a seam or rule changed"

gh pr edit --add-label "status:in-review"
```

End commit messages and the PR body with the trailers the repo uses:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
and for PR bodies:
```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

## 7. The test-before-merge gate

Two tiers — **both** must pass before merge:

1. **Automated (CI, on every PR):** `.github/workflows/validate.yml` runs
   `just prepare && just validate` in an Arch container. The PR must be green.
   This does **not** build an ISO.
2. **Manual (maintainer only):** the maintainer bakes and boots a full ISO
   and exercises the feature:
   ```sh
   just build            # full ISO into out/
   just vm               # boot the live ISO
   just vm --installed   # or boot an installed system
   ```
   Then runs the PR's **How to test** steps, confirms the feature works **and
   that reverting restores vanilla**, and only then merges.

Your PR is not "done" when CI is green — it is done when its **How to test**
section is so precise the maintainer can verify it without guessing. Write it
that way.

---

## 8. After merge

- The PR's `Closes #N` auto-closes the issue.
- The maintainer (or you, if asked) removes `status:claimed` and any
  `blocked` labels from issues this one unblocked.
- If your issue unblocked others, mention them so the maintainer can flip
  them to `status:available`.

---

## 9. Stale / abandoned claims

If a session dies mid-work, the maintainer removes `status:claimed` +
assignee and re-adds `status:available`. Before reclaiming a stale issue,
check for an existing `feat/<slug>` branch and build on it rather than
restarting.

---

## 10. Command cheat-sheet

```sh
gh issue list --label status:available --state open      # find work
gh issue view <N>                                         # read it fully
gh issue edit <N> --add-label status:claimed --remove-label status:available
gh issue edit <N> --add-assignee @me
gh issue comment <N> --body "..."                         # claim note
git switch -c feat/<slug>                                 # branch
just prepare && just validate                             # automated gate
gh pr create --base main --title "..." --body "Closes #<N> ..."
gh pr edit --add-label status:in-review
```

**Golden rule:** when in doubt, prefer the *more reversible* option, and ask
in an issue comment rather than guessing at a non-additive change.
