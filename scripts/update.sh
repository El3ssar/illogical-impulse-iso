#!/usr/bin/env bash
# update — manage the dots-hyprland submodule pin.
#
#   update.sh           fetch + fast-forward the submodule to upstream HEAD
#   update.sh --check   dry-run the bump policy (knobs in [upstream] of
#                       distro.toml); exit 0 = bump warranted, 1 = not yet.
#                       This is what the CI cron will call (phase 5).
#
# "Days since last release" is approximated by the age of the currently
# pinned commit — good enough until real releases exist to compare against.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE="${1:-}"
cd "$DOTS"
[[ -e .git ]] || die "not a git checkout — run: just setup"

git fetch --quiet origin || die "git fetch failed"
REMOTE_HEAD="$(git ls-remote --symref origin HEAD | awk '/^ref:/{print $2}' | sed 's@refs/heads/@@')"
[[ -n "$REMOTE_HEAD" ]] || REMOTE_HEAD=main

NEW_COMMITS="$(git rev-list --count "HEAD..origin/$REMOTE_HEAD")"
PIN_AGE_DAYS=$(( ( $(date +%s) - $(git log -1 --format=%ct HEAD) ) / 86400 ))
MIN_DAYS="$(tget upstream.min_days_between_releases)"
REQUIRE_NEW="$(tget upstream.require_new_commits)"

# The skel-shadow collision lint (tools/lint-additive.sh, PROPOSAL §4 Pillar 6)
# that catches a dots bump newly colliding with overlay/skel-distro runs in
# `just validate`, NOT here: it diffs against build/airootfs/etc/skel-upstream,
# which only exists after `just prepare`. The release flow already gates on a
# post-bump `just prepare && just validate` (BLUEPRINT §7), so a bump that
# introduces a collision fails there. Wiring it into this pre-prepare dry-run
# would need a second upstream-set source — deferred (issue #8 step 10, optional).
if [[ "$MODE" == "--check" ]]; then
  step "bump policy check"
  info "pinned:        $(git rev-parse --short HEAD) (${PIN_AGE_DAYS}d old)"
  info "upstream:      origin/$REMOTE_HEAD (+$NEW_COMMITS commits)"
  info "policy:        min ${MIN_DAYS}d between releases, require_new_commits=$REQUIRE_NEW"
  # Stable-pin relationship (#27). The submodule HEAD IS the next build's stable
  # DOTS_COMMIT: 70-assets.sh stamps `git -C $DOTS rev-parse --short HEAD` into
  # /etc/illogical-impulse/release, and `iictl update` (default channel=stable)
  # checks out exactly that commit. So a bump here automatically advances the
  # pin — the recorded pin can never drift from the submodule (validate.sh
  # asserts the two agree at build time, the anti-rot guard).
  info "stable pin:    DOTS_COMMIT = submodule HEAD ($(git rev-parse --short HEAD)) → next build's stable channel pin"
  if (( PIN_AGE_DAYS < MIN_DAYS )); then
    ok "no bump — pin younger than ${MIN_DAYS}d"
    exit 1
  fi
  if [[ "$REQUIRE_NEW" == "true" ]] && (( NEW_COMMITS == 0 )); then
    ok "no bump — no new upstream commits"
    exit 1
  fi
  ok "bump warranted"
  exit 0
fi

[[ "$MODE" == "" ]] || die "unknown option: $MODE (only --check)"

step "refresh upstream/illogical-impulse"
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes in $DOTS"
OLD="$(git rev-parse HEAD)"
git checkout -q -B "$REMOTE_HEAD" "origin/$REMOTE_HEAD"
git submodule update --init --recursive --quiet
NEW="$(git rev-parse HEAD)"
if [[ "$OLD" == "$NEW" ]]; then
  ok "already at origin/$REMOTE_HEAD"
else
  ok "$OLD → $NEW"
  git --no-pager log --oneline "$OLD..$NEW" | head -10 | sed 's/^/      /' >&2
  # The bumped submodule HEAD becomes the next build's stable DOTS_COMMIT
  # automatically (70-assets.sh stamps it; `iictl update` checks it out on the
  # default stable channel) — the recorded pin always follows the submodule pin,
  # so the two can never rot apart (#27; validate.sh asserts it at build time).
  info "stable pin:    next build will record DOTS_COMMIT=$(git rev-parse --short HEAD) as the stable channel pin"
  info "next: just prepare && just validate, then commit the submodule pin"
fi
