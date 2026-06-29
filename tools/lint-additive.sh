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
#   (7) pack-hook hygiene (IMMUNE-03): every packages/optional/<pack>.d/
#       {post-add,post-remove} fragment is `bash -n`-clean, every post-add has a
#       matching post-remove (#25 step-10b), and a post-add that applies a
#       reversible side effect via a mutator has a post-remove that calls the
#       symmetric inverse — so `iictl pack remove` undoes exactly what `iictl pack
#       install` did, not just a global `revert-all`.
#   (7b) pack Iron-Law guards (#25 step-10 a/c/d/e/f): over the gaming/creative/
#       laptop/security/virt/backup/flatpak-extras packs — (a) NO multilib toggle
#       anywhere (it is pre-enabled; declare lib32-* directly), (c) every
#       custom/*.lua write goes through the fenced helper (no raw append/tee/sed),
#       (d) the backup snapshot loader entry is gated on a runtime btrfs check,
#       (e) no PAM/group mutation is an in-place vendor-file edit (ii-owned
#       drop-ins + the group mutator only), (f) no manifest/hook references an
#       upstream-owned path.
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

  # #19 step 10(d): rsync --delete'd upstream-owned config trees a pack manifest
  # OR hook must never write to / reference (it would be wiped on 'iictl update'
  # or clobber upstream). Substring match — any occurrence in a manifest line or a
  # hook body is a fail. Mirrors the mutator's refusal set + PROPOSAL §3 row 4.
  local upstream_paths=(
    'quickshell/ii' 'matugen' 'fish/config.fish' 'zshrc.d' 'hypr/hyprland'
  )

  local l name lbad tool up
  local l name lbad is_flatpak
  for l in "${lists[@]}"; do
    lbad=0
    # A `#meta:type flatpak` pack's "members" are not heavy pacman packages being
    # fetched-on-demand — its apps are Flathub app-ids (declared as #meta:app),
    # and its single pacman member is the already-baked `flatpak` ENABLER (it has
    # to be present for the hook to add the remote + install the apps). That
    # enabler is intentionally baked (goodies.list), so the no-double-bake rule
    # (aimed at heavy software baked AND fetched) does not apply to it. Detect the
    # flatpak type up front and skip the baked-member assertion for such packs.
    is_flatpak=0
    grep -qE '^#meta:type[[:space:]]+flatpak([[:space:]]|$)' "$l" && is_flatpak=1
    while IFS= read -r ln; do
      ln="${ln%$'\r'}"
      [[ -z "${ln//[[:space:]]/}" ]] && continue            # blank line
      if [[ "$ln" == '#meta:'* ]]; then
        # well-formed: '#meta:<key>' or '#meta:<key> <value...>' (key = [a-z]+)
        # (key allows a trailing '-' so '#meta:app' and any future hyphenated key
        # parse; the original [a-z]+ already covered the keys this repo uses.)
        if [[ ! "$ln" =~ ^#meta:[a-z][a-z-]*([[:space:]].*)?$ ]]; then
          _v_fail "optional/$(basename "$l"): malformed #meta line: '$ln' (expect '#meta:<key> [value]')"
          lbad=$((lbad+1))
        fi
        continue
      fi
      # #19: `mise:<tool>[@<version>]` runtime directive (PROPOSAL §7). The engine
      # parses these as `mise use -g <tool>`, NOT pacman packages, so validate the
      # directive grammar here and DO NOT treat the token as a package name.
      if [[ "$ln" == 'mise:'* ]]; then
        tool="${ln#mise:}"; tool="${tool%%#*}"; tool="${tool//[[:space:]]/}"
        if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(@[A-Za-z0-9][A-Za-z0-9._+-]*)?$ ]]; then
          _v_fail "optional/$(basename "$l"): malformed mise directive: '$ln' (expect 'mise:<tool>[@<version>]')"
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
        if (( is_flatpak )); then
          continue   # the baked flatpak enabler — by design, not a double-bake
        fi
        _v_fail "optional/$(basename "$l"): member '$name' is ALSO baked into packages.x86_64 — optional packs install online, never double-bake"
        lbad=$((lbad+1))
      fi
    done < "$l"
    # 10(d): no upstream-owned path in a NON-comment manifest line (a package or
    # mise: line). Explanatory '#' comments naming the tree to say "we don't touch
    # it" are allowed; an actual member/directive pointing at it is not.
    for up in "${upstream_paths[@]}"; do
      if grep -vE '^[[:space:]]*#' "$l" | grep -Fq "$up"; then
        _v_fail "optional/$(basename "$l"): references upstream-owned path '$up' in a member/directive line — packs must never write/reference the rsync --delete'd tree (#19 step 10d)"
        lbad=$((lbad+1))
      fi
    done
    (( lbad == 0 )) && _v_ok "optional/$(basename "$l"): valid manifest (names/mise:/#meta:), no baked member, no upstream path"
  done

  # #19 step 10(c): ai-dev's GPU PCI detection MUST live in the hook (PCI is real
  # on the target), NOT in the manifest. Assert the manifest carries no PCI walk /
  # variant token and the post-add hook does. Only runs when ai-dev is authored.
  local aidev="$optdir/ai-dev.list" aidev_hook="$optdir/ai-dev.d/post-add"
  if [[ -f "$aidev" ]]; then
    # Scan NON-comment lines only: a comment explaining "the variant is chosen in
    # the hook" is fine; an actual `ollama-cuda` member or a PCI walk is not.
    if grep -vE '^[[:space:]]*#' "$aidev" | grep -Eq 'sys/bus/pci|0x10de|0x1002|ollama-cuda|ollama-rocm'; then
      _v_fail "optional/ai-dev.list: carries a GPU PCI-detect / ollama-cuda|rocm MEMBER — that detection belongs in ai-dev.d/post-add (PCI is real on the target), not the manifest (#19 step 10c)"
    else
      _v_ok "optional/ai-dev.list: no PCI-detect member in the manifest (correct — it lives in the hook) (#19 step 10c)"
    fi
    if [[ -f "$aidev_hook" ]]; then
      if grep -q 'sys/bus/pci' "$aidev_hook" && grep -Eq 'ollama-cuda|ollama-rocm' "$aidev_hook"; then
        _v_ok "optional/ai-dev.d/post-add: PCI-detects the GPU and selects the ollama variant in the hook (#19 step 10c)"
      else
        _v_fail "optional/ai-dev.d/post-add: missing the /sys/bus/pci GPU walk + ollama-cuda|rocm selection — ai-dev cannot pick the accelerated variant (#19 step 10c)"
      fi
    else
      _v_fail "optional/ai-dev.d/post-add missing — ai-dev declares GPU-gated variants with no hook to install them (#19 step 10c)"
    fi
  fi

  # #19 step 10(d) cont.: hook bodies must also reference no upstream-owned path.
  local hd hf
  shopt -s nullglob
  for hf in "$optdir"/*.d/post-add "$optdir"/*.d/post-remove; do
    for up in "${upstream_paths[@]}"; do
      # The ai-dev hook legitimately NAMES the upstream tree in a comment to
      # explain why it does NOT write it; allow it only inside comment lines.
      if grep -Fq "$up" "$hf" && grep -vE '^[[:space:]]*#' "$hf" | grep -Fq "$up"; then
        _v_fail "optional/$(basename "$(dirname "$hf")")/$(basename "$hf"): code references upstream-owned path '$up' — hooks must never write the rsync --delete'd tree (#19 step 10d)"
      fi
    done
  done
  shopt -u nullglob
  return 0
}

# ── Check 7 — pack post-add/post-remove hook hygiene (IMMUNE-03) ────────────
# Pack hooks (packages/optional/<pack>.d/{post-add,post-remove}) are bash
# FRAGMENTS the engine SOURCES (iictl.d/pack:_run_hook), never executes — so a
# syntax error never trips `bash -n` at +x time and a missing symmetric inverse
# never surfaces until a user runs `iictl pack remove` and the side effect lingers
# (Iron Law violation: not reversible). Audit the repo source of truth
# (packages/optional/*.d/) statically so a broken or asymmetric hook fails the
# build, not the user's machine.
#
# Symmetry model: a post-add that applies a reversible side effect through a
# mutator (mutator.sh) MUST have a post-remove that calls the matching inverse,
# so `iictl pack remove <pack>` (which runs post-remove BEFORE removing the
# recorded package set) undoes exactly what post-add added — without leaning on a
# global `iictl revert-all`. The inverse map mirrors mutator.sh + revert-all's
# own inverses (revert-all uses the raw `gpasswd -d`/`chsh` for group/shell, as
# there is no ii_group_remove mutator). ii_conflicts_check is a pure gate that
# records nothing and applies no side effect → it needs no inverse.
_lint_pack_hooks() {
  local optdir="$PACKAGES/optional"
  [[ -d "$optdir" ]] || { _v_ok "pack hooks: no packages/optional/ — nothing to lint"; return 0; }

  # side-effecting mutator → extended-regex of acceptable inverse tokens the
  # symmetric post-remove may use (the inverse mutator OR the raw op revert-all
  # itself runs). Pure gates (ii_conflicts_check) are intentionally absent.
  local -A _inverse=(
    [ii_service_enable]='ii_service_disable|systemctl[[:space:]]+disable'
    [ii_service_disable]='ii_service_enable|systemctl[[:space:]]+enable'
    [ii_group_add]='gpasswd[[:space:]]+-d|ii_group_remove'
    [ii_chsh]='ii_chsh|chsh'
    [ii_lua_block_write]='ii_lua_block_remove'
  )

  local hookdirs=()
  shopt -s nullglob
  hookdirs=("$optdir"/*.d)
  shopt -u nullglob
  if (( ${#hookdirs[@]} == 0 )); then
    _v_ok "pack hooks: no <pack>.d/ hook dirs staged yet — nothing to lint"
    return 0
  fi

  local bad=0 checked=0 hd pack add rm phase hook mut
  for hd in "${hookdirs[@]}"; do
    pack="$(basename "${hd%.d}")"
    add="$hd/post-add"
    rm="$hd/post-remove"

    # (a) bash -n every present fragment. A missing fragment is fine (both are
    # optional); a present one that won't parse is a hard fail.
    for phase in post-add post-remove; do
      hook="$hd/$phase"
      [[ -f "$hook" ]] || continue
      checked=$((checked+1))
      if ! bash -n "$hook" 2>/dev/null; then
        _v_fail "pack hooks: $pack.d/$phase has a bash syntax error (sourced fragment — would break 'iictl pack' at runtime)"
        bad=$((bad+1))
      fi
    done

    # (b0) PAIRING (#25 step-10b): a pack that ships a post-add MUST also ship a
    # post-remove, full stop — even one with no recognised mutator (e.g. a pack
    # whose only post-add effect is an opt-in package the engine reverts; its
    # post-remove can be a documented no-op). This is the coarse contract the
    # finer per-mutator symmetry below refines. (A lone post-remove is fine — it
    # is a pure inverse with nothing to pair.)
    if [[ -f "$add" && ! -f "$rm" ]]; then
      _v_fail "pack hooks: $pack.d/post-add exists but $pack.d/post-remove is MISSING — every post-add must have a matching post-remove (#25)"
      bad=$((bad+1))
    fi

    # (b) symmetry: for each side-effecting mutator the post-add invokes, the
    # post-remove must call the matching inverse. Comment lines are stripped so
    # a mutator named only in a comment neither demands nor satisfies an inverse.
    [[ -f "$add" ]] || continue
    local add_code rm_code
    add_code="$(grep -vE '^[[:space:]]*#' "$add" 2>/dev/null)"
    rm_code="$([[ -f "$rm" ]] && grep -vE '^[[:space:]]*#' "$rm" 2>/dev/null || true)"
    for mut in "${!_inverse[@]}"; do
      # word-boundary match so ii_service_enable does not also hit a longer name
      grep -qE "(^|[^A-Za-z0-9_])$mut([^A-Za-z0-9_]|\$)" <<<"$add_code" || continue
      if [[ ! -f "$rm" ]]; then
        _v_fail "pack hooks: $pack.d/post-add calls $mut but there is NO post-remove — side effect would survive 'iictl pack remove' (not reversible)"
        bad=$((bad+1)); continue
      fi
      if ! grep -qE "${_inverse[$mut]}" <<<"$rm_code"; then
        _v_fail "pack hooks: $pack.d/post-add calls $mut but post-remove has no matching inverse (${_inverse[$mut]//[[:space:]]+/ }) — 'iictl pack remove' would not undo it"
        bad=$((bad+1))
      fi
    done
  done

  (( bad == 0 )) && _v_ok "pack hooks: $checked fragment(s) bash -n clean, post-add side effects have symmetric post-remove inverses (${#hookdirs[@]} hook dir(s))"
  return 0
}

# ── Check 7b — pack-hook Iron-Law guards (#25 step-10 a/c/d/e/f) ────────────
# Extra static guards over the packs authored by #25 (gaming/creative/laptop/
# security/virt/backup/flatpak-extras), enforcing the Iron Law at the manifest +
# hook level. All operate on the repo source of truth (packages/optional/), strip
# comments so prose can't satisfy/trip a grep, and add NOTHING on a clean repo.
#
# Assertions (lettered to match the issue's step-10):
#   (a) NO multilib toggle anywhere — multilib is pre-enabled in the installed
#       target pacman.conf; a pack must NEVER write/uncomment a [multilib] block
#       or run `pacman -Sy` to enable it. lib32-* members install against the
#       already-enabled repo. (gaming declares lib32-* directly.)
#   (c) every custom/*.lua write across hooks goes through the fenced helper
#       (ii_lua_block_write) — never a raw append/sed/tee into a custom/*.lua slot.
#   (d) the backup pack's snapshot loader entry is gated on a RUNTIME btrfs check
#       (findmnt -no FSTYPE /), so it is never written on a non-btrfs root.
#   (e) no PAM/group/socket mutation is an in-place edit of a VENDOR file — PAM
#       wiring is an ii-owned drop-in, groups go through the mutator; a hook must
#       not sed/tee/>> a vendor /etc/pam.d/* or /etc/group.
#   (f) no pack manifest or hook references an upstream-owned path (the rsync
#       --delete dot trees + the quickshell/matugen/fish/hypr-hyprland roots).
_lint_pack_extra() {
  local optdir="$PACKAGES/optional"
  [[ -d "$optdir" ]] || { _v_ok "pack Iron-Law guards: no packages/optional/ — nothing to lint"; return 0; }

  local lists=() hooks=()
  shopt -s nullglob
  lists=("$optdir"/*.list)
  hooks=("$optdir"/*.d/post-add "$optdir"/*.d/post-remove)
  shopt -u nullglob

  local bad=0 f code

  # (a) multilib toggle ban — scan BOTH lists and hooks. A toggle looks like an
  # uncommented [multilib] section header, a Include/Server line under one, or a
  # `pacman -Sy`/`pacman-conf`/sed that enables multilib. lib32-* package NAMES
  # are fine (that is the whole point — declare them, don't toggle the repo).
  local toggle_hit=0
  for f in "${lists[@]}" "${hooks[@]}"; do
    [[ -f "$f" ]] || continue
    code="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)"
    if grep -qE '^\s*\[multilib\]' <<<"$code" \
       || grep -qiE 'multilib' <<<"$code"; then
      _v_fail "pack Iron-Law (a): ${f#"$ROOT"/} mentions multilib — it is ALREADY enabled; never toggle it (declare lib32-* directly) (#25)"
      bad=$((bad+1)); toggle_hit=$((toggle_hit+1))
    fi
  done
  (( toggle_hit == 0 )) && _v_ok "pack Iron-Law (a): no multilib toggle in any pack manifest/hook (lib32-* install against the pre-enabled repo)"

  # (c) every custom/*.lua write uses the fenced helper. Forbid a raw redirect /
  # tee / sed / printf-into-file that targets a custom/*.lua slot in any hook.
  local fence_hit=0
  for f in "${hooks[@]}"; do
    [[ -f "$f" ]] || continue
    code="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)"
    # a raw write to custom/*.lua = `>`/`>>`/tee/sed -i with a custom/*.lua target.
    if grep -qE '(>>?|tee|sed -i)[^|;&]*custom/[^[:space:]]*\.lua' <<<"$code"; then
      _v_fail "pack Iron-Law (c): ${f#"$ROOT"/} writes a custom/*.lua slot raw — use ii_lua_block_write/remove (the ONE fenced helper) (#25)"
      bad=$((bad+1)); fence_hit=$((fence_hit+1))
    fi
  done
  (( fence_hit == 0 )) && _v_ok "pack Iron-Law (c): no raw custom/*.lua write in any hook (all go through the fenced helper)"

  # (d) backup snapshot entry gated on a runtime btrfs check. If a backup post-add
  # exists and writes the loader entry, it MUST consult `findmnt … FSTYPE /`.
  local backup_add="$optdir/backup.d/post-add"
  if [[ -f "$backup_add" ]]; then
    code="$(grep -vE '^[[:space:]]*#' "$backup_add" 2>/dev/null)"
    if grep -qE 'ii-snapshots\.conf' <<<"$code"; then
      if grep -qE 'findmnt[^|]*FSTYPE[^|]*/' <<<"$code" && grep -qE '\bbtrfs\b' <<<"$code"; then
        _v_ok "pack Iron-Law (d): backup snapshot loader entry is gated on a runtime btrfs check (findmnt -no FSTYPE /)"
      else
        _v_fail "pack Iron-Law (d): backup.d/post-add writes ii-snapshots.conf without a runtime btrfs gate (findmnt -no FSTYPE / == btrfs) (#25)"
        bad=$((bad+1))
      fi
    fi
  fi

  # (e) no in-place vendor-file edit. A hook must never sed -i / >> / tee a VENDOR
  # PAM file (/etc/pam.d/system-auth|login|sudo|… — NOT our ii-owned ii-*) or the
  # vendor /etc/group. ii-owned drop-ins (paths containing 'ii-' or under
  # /etc/illogical-impulse) and the group MUTATOR (usermod/gpasswd via
  # ii_group_add) are the sanctioned ways and are exempt.
  local vendor_hit=0
  for f in "${hooks[@]}"; do
    [[ -f "$f" ]] || continue
    code="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)"
    # in-place edit of a vendor /etc/pam.d/* file (an ii-owned ii-* drop-in is OK).
    if grep -qE '(sed -i|tee|>>?)[^|;&]*/etc/pam\.d/(system-auth|login|sudo|sddm|greetd|passwd|su)\b' <<<"$code" \
       || grep -qE '(sed -i)[^|;&]*/etc/pam\.d/[^[:space:]]+' <<<"$code"; then
      # allow only when the target is an ii-owned drop-in name.
      if ! grep -qE '/etc/pam\.d/ii-' <<<"$code"; then
        _v_fail "pack Iron-Law (e): ${f#"$ROOT"/} edits a vendor /etc/pam.d/* file in place — use an ii-owned drop-in (never edit a vendor PAM stack) (#25)"
        bad=$((bad+1)); vendor_hit=$((vendor_hit+1))
      fi
    fi
    # in-place edit of the vendor group db (groups go through ii_group_add).
    if grep -qE '(sed -i|tee|>>?)[^|;&]*/etc/group\b' <<<"$code"; then
      _v_fail "pack Iron-Law (e): ${f#"$ROOT"/} edits /etc/group in place — add groups via the ii_group_add mutator (#25)"
      bad=$((bad+1)); vendor_hit=$((vendor_hit+1))
    fi
  done
  (( vendor_hit == 0 )) && _v_ok "pack Iron-Law (e): no in-place vendor PAM/group edit in any hook (ii-owned drop-ins + the group mutator only)"

  # (f) no upstream-owned path reference. The rsync --delete dot trees + the
  # single-file sync slots are READ-ONLY to the distro; a pack manifest/hook must
  # not target any. (The sanctioned custom/*.lua slots are NOT upstream-owned —
  # they are the ignore_existing seam — so they are intentionally NOT listed.)
  local up_paths=(
    '.config/quickshell' '.config/matugen' '.config/fish/config.fish'
    '.config/zshrc.d' '.config/hypr/hyprland' '.config/fontconfig'
    'quickshell/ii'
  )
  local up_hit=0 p
  for f in "${lists[@]}" "${hooks[@]}"; do
    [[ -f "$f" ]] || continue
    code="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)"
    for p in "${up_paths[@]}"; do
      if grep -qF -- "$p" <<<"$code"; then
        _v_fail "pack Iron-Law (f): ${f#"$ROOT"/} references upstream-owned path '$p' — packs never touch the rsync --delete dot trees (#25)"
        bad=$((bad+1)); up_hit=$((up_hit+1))
      fi
    done
  done
  (( up_hit == 0 )) && _v_ok "pack Iron-Law (f): no pack manifest/hook references an upstream-owned path"

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
  _lint_pack_hooks
  _lint_pack_extra
  _lint_pii
  return 0
}
