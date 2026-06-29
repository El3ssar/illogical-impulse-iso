#!/usr/bin/env bash
# devdash card: a small resource summary (load / memory / root disk). Read-only.
set -u
load="$(uptime 2>/dev/null | sed 's/.*load average: //')"
mem="$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}')"
disk="$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2"  ("$5")"}')"
printf 'load   %s\n' "${load:-?}"
printf 'memory %s\n' "${mem:-?}"
printf 'disk   %s\n' "${disk:-?}"
