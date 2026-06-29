#!/usr/bin/env bash
# devdash card: git status of ~/Projects repos. Printed into the widget's Process
# pane (no upstream import). Kept as a real file so it is bash -n lintable and the
# QML carries no embedded-shell escaping. Read-only: never mutates a repo.
set -u
shopt -s nullglob
root="${PROJECTS_DIR:-$HOME/Projects}"
found=0
for d in "$root"/*/; do
  [[ -d "$d/.git" ]] || continue
  found=1
  name="$(basename "$d")"
  branch="$(git -C "$d" branch --show-current 2>/dev/null)"
  dirty="$(git -C "$d" status --porcelain 2>/dev/null | grep -c .)"
  printf '%-20s %-14s %s\n' "${name:0:20}" "${branch:-(detached)}" "${dirty} dirty"
done | head -12
(( found )) || echo "no git repos under $root"
