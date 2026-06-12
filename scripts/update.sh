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

if [[ "$MODE" == "--check" ]]; then
  step "bump policy check"
  info "pinned:        $(git rev-parse --short HEAD) (${PIN_AGE_DAYS}d old)"
  info "upstream:      origin/$REMOTE_HEAD (+$NEW_COMMITS commits)"
  info "policy:        min ${MIN_DAYS}d between releases, require_new_commits=$REQUIRE_NEW"
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
  info "next: just prepare && just validate, then commit the submodule pin"
fi
