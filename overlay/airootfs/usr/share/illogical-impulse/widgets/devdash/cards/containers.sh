#!/usr/bin/env bash
# devdash card: running containers (docker, else podman). Read-only `ps`.
set -u
if command -v docker >/dev/null 2>&1; then
  out="$(docker ps --format '{{.Names}}  {{.Status}}' 2>/dev/null)"
  engine=docker
elif command -v podman >/dev/null 2>&1; then
  out="$(podman ps --format '{{.Names}}  {{.Status}}' 2>/dev/null)"
  engine=podman
else
  echo "no docker / podman installed"
  exit 0
fi
if [[ -n "$out" ]]; then
  printf '%s\n' "$out" | head -10
else
  echo "($engine: no running containers)"
fi
