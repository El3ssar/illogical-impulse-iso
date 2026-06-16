# shellcheck shell=bash disable=SC2154
# lint-additive — the mechanical enforcer of the Iron Law (PROPOSAL §4 Pillar 6).
# Sourced by scripts/validate.sh (NOT run directly); it reuses validate.sh's
# _v_ok/_v_warn/_v_fail tallies and common.sh's env ($ROOT/$BUILD/$AIROOTFS/
# $OVERLAY/$PACKAGES). It writes nothing, needs no root/network, never touches
# upstream/. Static audit of repo sources + build/ outputs only.
#
# Pillar 6 names SIX checks. Three of them already landed inline in validate.sh
# when the framework substrate (#3) merged, and are deliberately NOT duplicated
# here (CLAUDE.md §"Historic bugs": don't fork battle-tested checks):
#
#   (2) sentinel-fenced custom/*.lua blocks  → validate.sh step
#         "sentinel-fenced custom/*.lua blocks"
#   (3) iictl.d/ plugin hygiene (+x/shebang/bash -n/#help:)
#                                            → validate.sh step
#         "iictl.d/ plugin architecture"
#   (5) ii-verify does NOT purge iictl.d/ledger.sh/mutator.sh
#                                            → validate.sh step "distro perks …"
#
# This file owns the four structural checks that were not yet covered:
#
#   (0) precondition: build/airootfs/etc/skel-upstream exists and is populated
#       (>=100 files + quickshell/ii) — HARD-fail and skip the collision check
#       rather than give a false pass on an empty basis (mirrors 30-skel.sh).
#   (1) skel-shadow: no overlay/skel-distro file and no skel-distro.fetch dest
#       collides with an upstream-owned path (exact shadow OR landing inside an
#       install_dir__sync rsync --delete dir), allowlisting only the empty
#       custom/*.lua slots + custom/scripts/ and the sanctioned OOB STATE seed.
#   (4) optional-list validity: every packages/optional/*.list parses (names +
#       well-formed #meta:) and no member is ALSO baked into packages.x86_64.
#   (6) PII guard: no baked dev-default carries a [user] block, the build host's
#       git identity, or (for dev defaults) an email-shaped token.
#
# Entry point: lint_additive  (called from a validate.sh step).

# ── Check 0 + 1 — skel-shadow collision ────────────────────────────────────
_lint_skel_shadow() {
  local skup="$AIROOTFS/etc/skel-upstream"
  local distro="$OVERLAY/skel-distro"
  local fetch="$OVERLAY/skel-distro.fetch"

  # Check 0 (precondition, HARD). The collision basis is the upstream file list
  # under skel-upstream; if that tree is missing or sparse (e.g. validate run
  # before 30-skel.sh) every shadow would silently pass. Mirror 30-skel.sh's own
  # guard exactly, FAIL loudly, and skip the collision check — never false-pass.
  if [[ ! -d "$skup" ]]; then
    _v_fail "skel-shadow: skel-upstream missing ($skup) — run 'just prepare' first; collision check SKIPPED (would false-pass on an empty basis)"
    return 0
  fi
  local n; n=$(find "$skup" -type f 2>/dev/null | wc -l)
  if [[ ! -d "$skup/.config/quickshell/ii" ]] || (( n < 100 )); then
    local q; q=$([[ -d "$skup/.config/quickshell/ii" ]] && echo present || echo MISSING)
    _v_fail "skel-shadow: skel-upstream sparse ($n files; quickshell/ii $q) — collision check SKIPPED (would false-pass). Re-run 'just prepare'."
    return 0
  fi

  # Upstream-owned file set (skel-relative), derived authoritatively from
  # skel-upstream so it evolves with the dots. EXCEPT: 30-skel.sh deliberately
  # copies overlay/skel-distro/.local/state into skel-upstream too (the OOB
  # kitty-theme.conf seed must also reach liveuser). Those are OURS, not
  # upstream's — subtract them so the sanctioned STATE seed is not flagged.
  local -A _up=()
  local f rel
  while IFS= read -r f; do
    rel="${f#"$skup"/}"
    _up["$rel"]=1
  done < <(find "$skup" -type f 2>/dev/null)
  if [[ -d "$distro/.local/state" ]]; then
    while IFS= read -r f; do
      rel="${f#"$distro"/}"
      unset "_up[$rel]"
    done < <(find "$distro/.local/state" -type f 2>/dev/null)
  fi

  # Directories upstream rsync --delete's WHOLESALE at 'iictl update' (PROPOSAL §3
  # row 4 / BLUEPRINT §3; 30-skel.sh's _skel_fetch_guard encodes the same seam
  # set). A distro file ANYWHERE under one collides even when upstream ships no
  # file at that exact path — the updater wipes the whole dir, so a sibling like
  # .config/fish/config.fish.bak would not survive. The single-FILE sync paths
  # (config.fish, starship.toml, hyprlock.conf) need no prefix entry: upstream
  # ships them, so they are in skel-upstream and the exact-shadow check above
  # already flags a distro file landing on them. skel-upstream alone can't tell a
  # --delete dir from a preserved ignore_existing custom/ slot, so this list is
  # the authority for the prefix half; the exact-shadow half stays data-driven.
  # KEEP coordinated with 30-skel.sh's denylist + PROPOSAL §3 row 4.
  local sync_dirs=(
    .config/quickshell .config/matugen .config/fish
    .config/zshrc.d .config/hypr/hyprland .config/fontconfig
  )
  # Carve-outs upstream EXCLUDES from its --delete, so the distro MAY write there:
  # the fish conf.d drop-in seam (30-skel.sh rsyncs fish with --exclude=conf.d;
  # BLUEPRINT §3 "excluded from upstream sync"). A path under one of these is not
  # a collision even though it sits inside a sync dir.
  local sync_exempt=( .config/fish/conf.d )

  local bad=0 d e exempt
  if [[ -d "$distro" ]]; then
    while IFS= read -r f; do
      rel="${f#"$distro"/}"
      # Allowlist: the preserved install_dir__ignore_existing custom/*.lua slots
      # (writes must be fenced — checked separately) + custom/scripts/.
      case "$rel" in
        .config/hypr/custom/env.lua|.config/hypr/custom/execs.lua|\
        .config/hypr/custom/general.lua|.config/hypr/custom/rules.lua|\
        .config/hypr/custom/variables.lua|.config/hypr/custom/scripts/*)
          continue ;;
      esac
      if [[ -n "${_up[$rel]:-}" ]]; then
        _v_fail "skel-shadow: overlay/skel-distro/$rel shadows an upstream-shipped file — not a sanctioned seam"
        bad=$((bad+1)); continue
      fi
      exempt=0
      for e in "${sync_exempt[@]}"; do
        [[ "$rel" == "$e" || "$rel" == "$e"/* ]] && { exempt=1; break; }
      done
      (( exempt )) && continue
      for d in "${sync_dirs[@]}"; do
        if [[ "$rel" == "$d" || "$rel" == "$d"/* ]]; then
          _v_fail "skel-shadow: overlay/skel-distro/$rel lands in upstream rsync --delete dir '$d' (wiped on 'iictl update')"
          bad=$((bad+1)); break
        fi
      done
    done < <(find "$distro" -type f 2>/dev/null)
  fi

  # skel-distro.fetch destinations (comment-only today; guard them anyway so a
  # future pinned tree can't be vendored onto an upstream-owned path).
  if [[ -f "$fetch" ]]; then
    local dest _u _r
    while read -r dest _u _r; do
      [[ -z "$dest" || "$dest" == \#* ]] && continue
      # Normalize the way the filesystem would when 30-skel.sh installs the dest
      # (./ prefix, trailing /, embedded /./ and // all collapse) so a dest like
      # .config/./nvim still matches the canonical .config/nvim in the upstream set.
      dest="${dest#./}"; dest="${dest%/}"
      while [[ "$dest" == *"/./"* ]]; do dest="${dest//\/.\//\/}"; done
      while [[ "$dest" == *"//"*  ]]; do dest="${dest//\/\//\/}"; done
      case "$dest" in
        .config/hypr/custom/env.lua|.config/hypr/custom/execs.lua|\
        .config/hypr/custom/general.lua|.config/hypr/custom/rules.lua|\
        .config/hypr/custom/variables.lua|.config/hypr/custom/scripts/*)
          continue ;;
      esac
      if [[ -n "${_up[$dest]:-}" ]]; then
        _v_fail "skel-shadow: skel-distro.fetch dest '$dest' shadows an upstream-shipped file — pick a distro-owned/unowned path"
        bad=$((bad+1)); continue
      fi
      exempt=0
      for e in "${sync_exempt[@]}"; do
        [[ "$dest" == "$e" || "$dest" == "$e"/* ]] && { exempt=1; break; }
      done
      (( exempt )) && continue
      for d in "${sync_dirs[@]}"; do
        if [[ "$dest" == "$d" || "$dest" == "$d"/* ]]; then
          _v_fail "skel-shadow: skel-distro.fetch dest '$dest' is in the upstream rsync --delete dir '$d' (wiped on 'iictl update')"
          bad=$((bad+1)); break
        fi
      done
    done < "$fetch"
  fi

  (( bad == 0 )) && _v_ok "skel-shadow: ${#_up[@]} upstream paths, no skel-distro/.fetch collision (custom/*.lua slots + OOB STATE seed exempt)"
  return 0
}

# ── Check 4 — packages/optional/*.list validity ────────────────────────────
_lint_optional_lists() {
  local optdir="$PACKAGES/optional" pkglist="$BUILD/packages.x86_64"
  local lists=()
  if [[ -d "$optdir" ]]; then
    shopt -s nullglob
    lists=("$optdir"/*.list)
    shopt -u nullglob
  fi
  if (( ${#lists[@]} == 0 )); then
    _v_ok "optional packs: no packages/optional/*.list staged yet — nothing to validate"
    return 0
  fi

  # Baked set: a member appearing here would be double-baked (optional packs are
  # FETCHED-ONLINE on demand by 'iictl pack', never baked — PROPOSAL §4 Pillar 1/7).
  local -A _baked=()
  local ln
  if [[ -f "$pkglist" ]]; then
    while IFS= read -r ln; do
      ln="${ln%%#*}"; ln="${ln//[[:space:]]/}"
      [[ -n "$ln" ]] && _baked["$ln"]=1
    done < "$pkglist"
  fi

  local l name lbad
  for l in "${lists[@]}"; do
    lbad=0
    while IFS= read -r ln; do
      ln="${ln%$'\r'}"
      [[ -z "${ln//[[:space:]]/}" ]] && continue            # blank line
      if [[ "$ln" == '#meta:'* ]]; then
        # well-formed: '#meta:<key>' or '#meta:<key> <value...>' (key = [a-z]+)
        if [[ ! "$ln" =~ ^#meta:[a-z][a-z]*([[:space:]].*)?$ ]]; then
          _v_fail "optional/$(basename "$l"): malformed #meta line: '$ln' (expect '#meta:<key> [value]')"
          lbad=$((lbad+1))
        fi
        continue
      fi
      [[ "$ln" == '#'* ]] && continue                       # ordinary comment
      name="${ln%%#*}"; name="${name//[[:space:]]/}"        # allow trailing inline comment
      [[ -z "$name" ]] && continue
      if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then
        _v_fail "optional/$(basename "$l"): not a valid package name: '$name'"
        lbad=$((lbad+1)); continue
      fi
      if [[ -n "${_baked[$name]:-}" ]]; then
        _v_fail "optional/$(basename "$l"): member '$name' is ALSO baked into packages.x86_64 — optional packs install online, never double-bake"
        lbad=$((lbad+1))
      fi
    done < "$l"
    (( lbad == 0 )) && _v_ok "optional/$(basename "$l"): valid manifest, no baked members"
  done
  return 0
}

# ── Check 6 — PII guard ────────────────────────────────────────────────────
_lint_pii() {
  local bad=0 file rel
  # The realistic accidental-bake vector is a contributor's own ~/.gitconfig
  # leaking into skel-distro. Derive the identity to forbid DYNAMICALLY from the
  # build host's git config — never hardcode anyone's name/email into the repo
  # (that would itself bake PII). Empty when git identity is unset (e.g. CI).
  local gname gemail
  gname=$(git -C "$ROOT" config user.name  2>/dev/null || true)
  gemail=$(git -C "$ROOT" config user.email 2>/dev/null || true)

  # A personal name has whitespace ("First Last"); CI service accounts
  # (github-actions, ci, root, deploy) do not. Only the former is matched as a
  # bare string — else a one-word CI user.name would spuriously hit 'root' in
  # /etc/passwd, 'admin' in sudoers, etc. and fail clean CI builds. The email is
  # always matched (it is the strong identifier and rarely collides).
  local gname_personal=0
  [[ -n "$gname" && "$gname" == *[[:space:]]* ]] && gname_personal=1

  # Pass 1 — structural guard across both baked trees: ANY [user] git/INI section
  # (bare, subsectioned, or mixed-case — git treats them all as identity) is wrong
  # in a baked file, and the build host's literal identity must never appear.
  while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    # -i + optional "subsection" + end-anchor: catches [user], [User], [user "x"];
    # not [username]. (git config section headers are case-insensitive.)
    if grep -Iqs -i -E '^[[:space:]]*\[user([[:space:]]+"[^"]*")?\][[:space:]]*$' "$file"; then
      _v_fail "PII: $rel has a [user] section — strip identity blocks from baked files"
      bad=$((bad+1))
    fi
    if (( gname_personal )) && grep -Iqs -F -- "$gname" "$file"; then
      _v_fail "PII: $rel contains the build host's git user.name — do not bake personal identity"
      bad=$((bad+1))
    fi
    if [[ -n "$gemail" ]] && grep -Iqs -F -- "$gemail" "$file"; then
      _v_fail "PII: $rel contains the build host's git user.email — do not bake personal identity"
      bad=$((bad+1))
    fi
  done < <(find "$OVERLAY/skel-distro" "$OVERLAY/airootfs" -type f 2>/dev/null)

  # Pass 2 — strict email scan of dev-default files ONLY (skel-distro). System
  # configs under airootfs may legitimately reference a distro support address,
  # so they are not blanket email-scanned; their identity risk is covered above.
  local email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+'
  while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    if grep -Iqs -E "$email_re" "$file"; then
      _v_fail "PII: $rel carries an email-shaped token — baked dev defaults must hold no identity"
      bad=$((bad+1))
    fi
  done < <(find "$OVERLAY/skel-distro" -type f 2>/dev/null)

  (( bad == 0 )) && _v_ok "PII guard: no [user] block, build-host identity, or baked email in skel-distro/airootfs dev defaults"
  return 0
}

# ── Entry point ────────────────────────────────────────────────────────────
lint_additive() {
  _lint_skel_shadow
  _lint_optional_lists
  _lint_pii
  return 0
}
