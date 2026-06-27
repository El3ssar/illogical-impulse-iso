# mutator.sh — idempotent, reversible, ledger-recording system-touch primitives.
#
# Staged to /usr/local/lib/ii/mutator.sh (a survive-path — kept by ii-verify so
# the installed system's iictl framework + `revert-all` can use it). Sourced by
# iictl.d/ plugins that change the system; it sources ledger.sh itself so the
# mutators always have ledger_record available. set -u-safe and side-effect-free
# on source (defines functions + namespaced II_* constants only).
#
# CONTRACT — this is the ONLY sanctioned way to touch services, group
# memberships, login shells, and the upstream custom/*.lua slots. Every
# primitive is:
#   • idempotent — calling it twice is safe: it no-ops (and records nothing)
#     when the system is already in the target state, so no duplicate ledger
#     rows, group memberships, or fenced blocks accrue;
#   • reversible — it records its inverse in the ledger BEFORE/while acting, so
#     `iictl revert-all` (#4) can undo it from the recorded restore hint;
#   • offline/chroot-safe — `systemctl enable/disable` only manipulate symlinks
#     (no running daemon needed), so they work in the install chroot.
#
# ── THE SENTINEL-FENCE CONVENTION (framework-owned, MANDATORY) ───────────────
# Every block the distro writes into a sanctioned upstream custom/*.lua slot
# (`~/.config/hypr/custom/{env,execs,general,rules,variables}.lua` — the
# `install_dir__ignore_existing` seam; PROPOSAL §3) MUST be wrapped in a named
# sentinel fence:
#
#     -- >>> illogical-impulse <name>
#     ...our lines...
#     -- <<< illogical-impulse <name>
#
# Rules:
#   • ALL reads/writes of these slots go through ONE shared helper pair —
#     ii_lua_block_write / ii_lua_block_remove (both share _ii_lua_strip). No
#     other code may hand-append to a custom/*.lua slot.
#   • A fence is individually strippable: ii_lua_block_remove deletes exactly
#     the named region, leaving upstream's stub and any user lines intact —
#     that is what makes `revert-all` restore vanilla.
#   • Writes are confined to the custom/*.lua slots ONLY; the mutator refuses any
#     other path. It never touches the rsync --delete'd tree (quickshell/ii,
#     matugen, fish/config.fish, zshrc.d, hypr/hyprland) or upstream runtime
#     STATE — those are READ-ONLY (PROPOSAL §3, BLUEPRINT §"Seam classes").
#   • validate.sh enforces that every distro-authored custom/*.lua block is
#     fenced (bug-class guard, Iron Rule).

II_LIB="${II_LIB:-/usr/local/lib/ii}"
# Source the ledger (guarded so a dev checkout without the staged tree still
# loads). Side-effect-free; double-sourcing via iictl-common.sh is harmless.
[[ -r "$II_LIB/ledger.sh" ]] && source "$II_LIB/ledger.sh"

# Fence marker prefixes — the block <name> is appended to each.
II_FENCE_OPEN='-- >>> illogical-impulse '
II_FENCE_CLOSE='-- <<< illogical-impulse '

# Self-contained error helper (mutator.sh must not depend on iictl-common.sh's
# die — it is sourced standalone in tests and by ii-post-install).
_ii_mut_err() { printf 'ii-mutator: %s\n' "$*" >&2; }

# ── services ─────────────────────────────────────────────────────────────────
# ii_service_enable <unit> — enable a unit idempotently, recording the prior
# enabled-state so revert can restore it. `systemctl enable` only writes the
# [Install] .wants symlinks (no daemon needed) → chroot/offline-safe.
ii_service_enable() {
  local unit="${1:-}"; [[ -n "$unit" ]] || { _ii_mut_err "ii_service_enable: no unit"; return 1; }
  local prior; prior="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  [[ "$prior" == "enabled" ]] && return 0   # already enabled → nothing to do/record
  systemctl enable "$unit" >/dev/null 2>&1 || { _ii_mut_err "enable $unit failed"; return 1; }
  ledger_record service "$unit" "" "" "${prior:-disabled}"
}

# ii_service_disable <unit> — disable a unit idempotently, recording the prior
# state so revert can re-enable it.
ii_service_disable() {
  local unit="${1:-}"; [[ -n "$unit" ]] || { _ii_mut_err "ii_service_disable: no unit"; return 1; }
  local prior; prior="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  [[ "$prior" == "disabled" || "$prior" == "masked" ]] && return 0
  systemctl disable "$unit" >/dev/null 2>&1 || { _ii_mut_err "disable $unit failed"; return 1; }
  ledger_record service-disable "$unit" "" "" "${prior:-enabled}"
}

# ── groups ───────────────────────────────────────────────────────────────────
_ii_in_group() {   # _ii_in_group <user> <group> — true if already a member
  local user="$1" grp="$2" g
  for g in $(id -nG "$user" 2>/dev/null); do [[ "$g" == "$grp" ]] && return 0; done
  return 1
}

# ii_group_add <user> <group...> — add the user to each group idempotently
# (groupadd -f first). Records ONLY the memberships WE add (skips and does not
# record ones already present) so revert removes only ours. Mirrors the raw
# usermod -aG pattern in ii-post-install, made reversible.
#
# Install-time vs iictl-time tagging: set II_GROUP_SRC=install in the environment
# to mark the recorded rows as install-time distro setup — the restore_hint then
# carries the reserved `src=install` token alongside `user=<u>`, so revert-all's
# `_is_install_row` gates them under `--deep` (BLUEPRINT §"Two-tier"). The
# default (unset) records `user=<u>` only → an iictl-time row a plain
# `iictl revert-all` peels (the pack-post-add path). The two tokens are
# space-separated and order-independent: revert-all extracts `user=` by token
# scan, so a co-present `src=install` never corrupts the username.
ii_group_add() {
  local user="${1:-}"; shift || true
  [[ -n "$user" ]] || { _ii_mut_err "ii_group_add: no user"; return 1; }
  local hint="user=$user"
  [[ "${II_GROUP_SRC:-}" == install ]] && hint="$hint src=install"
  local g rc=0
  for g in "$@"; do
    [[ -n "$g" ]] || continue
    groupadd -f "$g" 2>/dev/null || true
    _ii_in_group "$user" "$g" && continue   # already a member → not ours to revert
    if usermod -aG "$g" "$user" 2>/dev/null || gpasswd -a "$user" "$g" >/dev/null 2>&1; then
      ledger_record group "$g" "" "" "$hint"
    else
      _ii_mut_err "group add $g for $user failed"; rc=1
    fi
  done
  return $rc
}

# ── sentinel-fenced custom/*.lua slots ───────────────────────────────────────
# _ii_lua_strip <file> <name> — print <file> to stdout with the named fenced
# region removed. The ONE shared routine behind both write and remove. Exact
# line match on the fence markers so user lines are never touched.
_ii_lua_strip() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  # NB: awk var names avoid gawk builtins (`close` is reserved) → fbeg/fend.
  awk -v fbeg="$II_FENCE_OPEN$name" -v fend="$II_FENCE_CLOSE$name" '
    $0 == fbeg  { inblk = 1; next }
    inblk && $0 == fend { inblk = 0; next }
    !inblk { print }
  ' "$file"
}

_ii_is_custom_lua() {   # only the sanctioned hypr custom/*.lua slots are writable
  case "$1" in */.config/hypr/custom/*.lua) return 0 ;; *) return 1 ;; esac
}

# ii_lua_block_write <file> <name>   (block body on stdin)
# Write/replace a sentinel-fenced block named <name> in a custom/*.lua slot.
# Idempotent: an existing same-named block is replaced (never duplicated); if
# the resulting file is byte-identical to the old one, it records nothing.
# Refuses any non-custom path. Records kind=lua-block, owned_paths=<file>,
# restore_hint=<name>.
ii_lua_block_write() {
  local file="${1:-}" name="${2:-}"
  [[ -n "$file" && -n "$name" ]] || { _ii_mut_err "ii_lua_block_write <file> <name>"; return 1; }
  _ii_is_custom_lua "$file" || { _ii_mut_err "refusing non-custom path: $file"; return 1; }
  local body; body="$(cat)"   # block body from stdin
  mkdir -p "$(dirname "$file")" 2>/dev/null || { _ii_mut_err "mkdir for $file failed"; return 1; }
  local tmp; tmp="$(mktemp)" || return 1
  _ii_lua_strip "$file" "$name" > "$tmp"
  { printf '%s%s\n' "$II_FENCE_OPEN" "$name"
    printf '%s\n' "$body"
    printf '%s%s\n' "$II_FENCE_CLOSE" "$name"
  } >> "$tmp"
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"; return 0   # no change → idempotent, no duplicate ledger row
  fi
  cat "$tmp" > "$file" && rm -f "$tmp" || { _ii_mut_err "write $file failed"; rm -f "$tmp"; return 1; }
  ledger_record lua-block "$file" "" "$file" "$name"
}

# ii_lua_block_remove <file> <name> — strip exactly the named fenced region.
# Used by `revert-all`; records nothing (it IS the inverse). No-op if absent.
ii_lua_block_remove() {
  local file="${1:-}" name="${2:-}"
  [[ -n "$file" && -n "$name" ]] || { _ii_mut_err "ii_lua_block_remove <file> <name>"; return 1; }
  [[ -f "$file" ]] || return 0
  local tmp; tmp="$(mktemp)" || return 1
  _ii_lua_strip "$file" "$name" > "$tmp"
  if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi   # block wasn't present
  cat "$tmp" > "$file" && rm -f "$tmp" || { _ii_mut_err "rewrite $file failed"; rm -f "$tmp"; return 1; }
}

# ── login shell ──────────────────────────────────────────────────────────────
# ii_chsh <user> <shell-abs-path> — register the shell in /etc/shells FIRST
# (idempotently — AUR shells like fizsh/nushell are not there by default, so
# chsh fails or PAM-prompts otherwise), then chsh, recording the prior login
# shell so revert can restore it. Idempotent: no-op if already the login shell.
ii_chsh() {
  local user="${1:-}" shell="${2:-}"
  [[ -n "$user" && -n "$shell" ]] || { _ii_mut_err "ii_chsh <user> <shell>"; return 1; }
  [[ -x "$shell" ]] || { _ii_mut_err "shell not executable: $shell"; return 1; }
  grep -qxF "$shell" /etc/shells 2>/dev/null \
    || printf '%s\n' "$shell" >> /etc/shells 2>/dev/null || true
  local prior; prior="$(getent passwd "$user" 2>/dev/null | cut -d: -f7)"
  [[ "$prior" == "$shell" ]] && return 0   # already the login shell
  chsh -s "$shell" "$user" >/dev/null 2>&1 || { _ii_mut_err "chsh $user → $shell failed"; return 1; }
  ledger_record chsh "$user" "" "" "${prior:-/bin/bash}"
}

# ── conflict gate ────────────────────────────────────────────────────────────
# ii_conflicts_check <pkg...> — fail (non-zero) BEFORE any pacman runs if any of
# the named (declared via a pack's #meta:conflicts) packages is already
# installed — the laptop power-tool mutual-exclusion case. Records nothing.
ii_conflicts_check() {
  local pkg conflicts=()
  for pkg in "$@"; do
    [[ -n "$pkg" ]] || continue
    pacman -Qq "$pkg" >/dev/null 2>&1 && conflicts+=("$pkg")
  done
  if (( ${#conflicts[@]} > 0 )); then
    _ii_mut_err "conflicting package(s) already installed: ${conflicts[*]}"
    return 1
  fi
  return 0
}
