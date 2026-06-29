#!/usr/bin/env bash
# devdash card: recent CI runs for the repo in $PWD-or-~/Projects via gh. Read-
# only `gh run list`. Degrades clearly when gh is absent or unauthenticated.
set -u
if ! command -v gh >/dev/null 2>&1; then
  echo "github-cli (gh) not installed"
  exit 0
fi
dir="${CI_REPO_DIR:-$HOME/Projects}"
# Pick the first ~/Projects repo with a GitHub remote so the card has a subject.
repo=""
shopt -s nullglob
for d in "$dir"/*/; do
  [[ -d "$d/.git" ]] || continue
  if git -C "$d" remote get-url origin 2>/dev/null | grep -q github.com; then
    repo="$d"; break
  fi
done
[[ -n "$repo" ]] || repo="$dir"
out="$(cd "$repo" 2>/dev/null && gh run list --limit 6 2>/dev/null | tr '\t' ' ')"
if [[ -n "$out" ]]; then
  printf 'repo: %s\n%s\n' "$(basename "$repo")" "$out"
else
  echo "gh: no runs (not a gh repo, or not authenticated — try: gh auth login)"
fi
