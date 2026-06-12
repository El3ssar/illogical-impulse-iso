#!/usr/bin/env bash
# publish-sf — upload release artifacts to the SourceForge file area, with
# resumable retries and remote size verification. The SAME script runs
# locally and in CI, so publishing logic is testable in seconds with a
# dummy file instead of via one-hour release runs.
#
#   publish-sf.sh <version-folder> <file> [file...]   upload + verify
#   publish-sf.sh --verify <version-folder> <file...> verify sizes only
#   publish-sf.sh --ls [version-folder]               list remote files
#   publish-sf.sh --rm <version-folder> <name...>     delete remote files
#
# Env: SF_KEY — ssh private key path (default: ~/.ssh/ii_sf_release).
# User/project come from distro.toml [release].
#
# SourceForge quirks encoded here (each cost a failed release):
#   * FRS rejects chmod/utimes on its dirs → rsync must run WITHOUT -a
#     (plain -r, no attribute options), or it aborts with exit 23.
#   * sftp `ls -l <path>` echoes the full requested path in the name
#     column → always `cd` first and match basenames.
#   * "Could not chdir to home directory" on connect is cosmetic.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require rsync sftp

SF_USER="$(tget release.sf_user)"
SF_PROJECT="$(tget release.sf_project)"
SF_KEY="${SF_KEY:-$HOME/.ssh/ii_sf_release}"
[[ -f "$SF_KEY" ]] || die "ssh key not found: $SF_KEY (set SF_KEY)"
SSH_OPTS=(-i "$SF_KEY" -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
HOST="$SF_USER@frs.sourceforge.net"
BASE="/home/frs/project/$SF_PROJECT"

_sftp() { sftp -q -b - "${SSH_OPTS[@]}" "$HOST" 2>/dev/null; }

# Remote byte size of $2 inside version-folder $1 ('' if absent).
_remote_size() {
  printf 'cd %s/%s\nls -l\n' "$BASE" "$1" | _sftp \
    | awk -v n="$2" '$NF == n {print $5; exit}'
}

_verify() {
  local ver="$1"; shift
  local f name local_size remote_size bad=0
  for f in "$@"; do
    name=$(basename "$f")
    local_size=$(stat -c%s "$f")
    remote_size=$(_remote_size "$ver" "$name")
    if [[ "$local_size" == "$remote_size" && -n "$remote_size" ]]; then
      ok "$name: $remote_size bytes (matches)"
    else
      bad=1
      printf '   %sFAIL%s %s: local=%s remote=%s\n' \
        "$C_R" "$C_0" "$name" "$local_size" "${remote_size:-<missing>}" >&2
    fi
  done
  return $bad
}

MODE=upload
case "${1:-}" in
  --verify) MODE=verify; shift ;;
  --ls)     MODE=ls;     shift ;;
  --rm)     MODE=rm;     shift ;;
esac

case "$MODE" in
  ls)
    printf 'cd %s/%s\nls -l\n' "$BASE" "${1:-}" | _sftp | grep -v '^sftp>'
    ;;
  rm)
    VER="${1:?--rm needs <version-folder> <name...>}"; shift
    (( $# > 0 )) || die "--rm needs file names"
    { for n in "$@"; do printf 'rm %s/%s/%s\n' "$BASE" "$VER" "$n"; done; } | _sftp >/dev/null
    ok "removed $* from $VER/"
    ;;
  verify)
    VER="${1:?need <version-folder>}"; shift
    _verify "$VER" "$@"
    ;;
  upload)
    VER="${1:?need <version-folder> <file...>}"; shift
    (( $# > 0 )) || die "nothing to upload"
    for f in "$@"; do [[ -f "$f" ]] || die "no such file: $f"; done

    STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
    install -d "$STAGE/$VER"
    cp "$@" "$STAGE/$VER/"

    step "upload → sourceforge:/$SF_PROJECT/$VER/ ($(du -sh "$STAGE/$VER" | cut -f1))"
    done_=0
    for attempt in 1 2 3 4 5; do
      if rsync -rv --partial --timeout=120 -e "ssh ${SSH_OPTS[*]}" \
           "$STAGE/" "$HOST:$BASE/"; then
        done_=1; break
      fi
      warn "rsync attempt $attempt failed — retrying in 30s"
      sleep 30
    done
    (( done_ )) || die "upload failed after 5 attempts"

    step "verify remote sizes"
    _verify "$VER" "$@" || die "remote size verification failed"
    ok "published: https://sourceforge.net/projects/$SF_PROJECT/files/$VER/"
    ;;
esac
