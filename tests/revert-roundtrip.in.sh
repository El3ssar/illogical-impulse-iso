#!/usr/bin/env bash
# revert-roundtrip.in.sh — the IN-CONTAINER half of the Iron Law round-trip test.
#
# This is the payload that runs INSIDE the throwaway `just nspawn` container (see
# tests/revert-roundtrip.sh, the host driver, for how it gets there). It proves
# the project's central promise end-to-end on the REAL, already-merged code:
#
#   "delete our additions + run `iictl revert-all` → vanilla upstream returns."
#
# It does NOT touch the mutators / ledger / revert-all logic — it exercises them
# exactly as a real install would, then asserts the system is byte-for-byte back
# to its pristine pre-seed baseline. The container is ephemeral (--volatile=
# overlay), so every change here evaporates on exit: the test leaves no residue
# on the host or the cached base rootfs by construction.
#
# Flow:
#   1. set up a real non-root user with passwordless sudo (the install scenario:
#      iictl revert-all + iictl pack call _not_root and use sudo for the
#      privileged inverses);
#   2. capture a PRISTINE baseline (service enabled-state, group membership, the
#      custom/*.lua slot's bytes, the installed-package presence);
#   3. SEED four ledger kinds through the REAL mutators + the REAL pack engine:
#        • ii_service_enable   → a static dummy unit  (kind=service)
#        • ii_group_add        → a fresh, non-docker group (kind=group, in scope)
#        • ii_lua_block_write  → a sentinel-fenced block in custom/general.lua
#        • iictl pack install   → a small official-repo pack (kind=pack)
#   4. assert revert-all --dry-run changes NOTHING (plan only, ledger untouched);
#   5. run revert-all for real (--deep so any install-classified row is in scope);
#   6. assert EVERY touched axis matches the pristine baseline byte-for-byte and
#      the ledger is drained.
#
# Exit 0 = the Iron Law holds. Any non-zero = a reversibility regression (e.g. a
# broken mutator inverse), which is exactly what this test exists to catch.

set -u

# ── test harness ─────────────────────────────────────────────────────────────
PASS=0 FAIL=0
C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_B=$'\e[1m' C_0=$'\e[0m'
_pass() { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
_fail() { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
_info() { printf '%s::%s %s\n'     "$C_B" "$C_0" "$*"; }
# _check <label> <expected> <actual> — string equality assertion.
_check() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then _pass "$label"
  else _fail "$label (want: [$want]  got: [$got])"; fi
}

# _ledger_rows <file> — count DATA rows (skip the header comment + blanks),
# mirroring ledger_query's row set. awk (not `grep -c`, which prints "0" AND
# exits 1 on no match → `grep -c … || echo 0` would yield a two-line "0\n0").
_ledger_rows() { [[ -f "$1" ]] && awk '!/^#/ && NF {n++} END{print n+0}' "$1" || echo 0; }

II_LIB="${II_LIB:-/usr/local/lib/ii}"
# Sanity: the survive-path framework must be staged in the container (nspawn.sh
# rsyncs build/airootfs/usr/local). Without it there is nothing to test.
for f in iictl-common.sh ledger.sh mutator.sh iictl.d/revert-all iictl.d/pack; do
  [[ -r "$II_LIB/$f" ]] || { printf '%sFATAL%s missing staged framework file: %s\n' "$C_R" "$C_0" "$II_LIB/$f" >&2; exit 2; }
done
command -v iictl >/dev/null 2>&1 || { printf '%sFATAL%s iictl not on PATH in container\n' "$C_R" "$C_0" >&2; exit 2; }

# ── 0. a real non-root user with passwordless sudo ───────────────────────────
# revert-all + pack refuse to run as root (_not_root) and shell privileged
# inverses through sudo — exactly the installed-system contract. Model that.
TESTUSER=iitester
TESTGROUP=ii-e2e-grp     # NEVER 'docker' → stays in the DEFAULT revert scope
DUMMY_UNIT=ii-e2e-dummy.service
LUA_NAME=ii-e2e
PACK=demo                # tiny official-repo pack (sl, cowsay) — never baked

_info "creating throwaway user '$TESTUSER' (passwordless sudo)"
useradd -m -s /bin/bash "$TESTUSER" 2>/dev/null || true
install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TESTUSER" > /etc/sudoers.d/99-ii-e2e
chmod 0440 /etc/sudoers.d/99-ii-e2e
USER_HOME="$(getent passwd "$TESTUSER" | cut -d: -f6)"

# run a command AS the test user, with the framework env exported through (so
# the user-side iictl/mutator calls resolve the same survive-path + ledger).
# PATH is set explicitly because sudo resets it to secure_path — without
# /usr/local/bin the user-side `iictl` (and revert-all's `command -v iictl`
# doctor re-run) would not be found.
as_user() {
  sudo -u "$TESTUSER" env \
    II_LIB="$II_LIB" HOME="$USER_HOME" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin" \
    "$@"
}
LEDGER="$USER_HOME/.local/state/illogical-impulse/ledger.tsv"
LUA_FILE="$USER_HOME/.config/hypr/custom/general.lua"

# ── a static, offline-enable-able dummy unit (no daemon needed) ──────────────
# ii_service_enable only writes the [Install] .wants symlink, so a plain static
# unit is enough to drive enable→record→disable round-trip with no network.
cat > /etc/systemd/system/"$DUMMY_UNIT" <<'UNIT'
[Unit]
Description=Illogical Impulse reversibility e2e dummy unit
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT

# A pristine upstream-style custom slot: an empty stub the user "owns". The
# fence writer must add ONLY its named region and revert must restore this
# exact byte content. (Upstream ships these as do-nothing stubs.)
install -d "$(dirname "$LUA_FILE")"
cat > "$LUA_FILE" <<'LUA'
-- custom/general.lua (upstream stub)
-- user lines live here and must survive a revert untouched
LUA
chown -R "$TESTUSER":"$TESTUSER" "$USER_HOME/.config"

# ════════════════════════════════════════════════════════════════════════════
# 1. PRISTINE BASELINE (captured BEFORE any seeding)
# ════════════════════════════════════════════════════════════════════════════
_info "capturing pristine baseline"
BASE_SVC="$(systemctl is-enabled "$DUMMY_UNIT" 2>/dev/null || echo disabled)"
BASE_GRP_MEMBER=no; id -nG "$TESTUSER" 2>/dev/null | tr ' ' '\n' | grep -qx "$TESTGROUP" && BASE_GRP_MEMBER=yes
BASE_LUA_SHA="$(sha256sum "$LUA_FILE" | cut -d' ' -f1)"
# A pack is a NAME-LIST, not a package — assert removal at the MEMBER level. The
# demo pack's members (resolve presence individually so we can prove revert
# removed exactly the ones the seed added, and left pre-present ones alone).
PACK_MEMBERS=(sl cowsay)
BASE_MEMBERS_PRESENT=()
for m in "${PACK_MEMBERS[@]}"; do
  pacman -Qq "$m" >/dev/null 2>&1 && BASE_MEMBERS_PRESENT+=("$m")
done
# no ledger yet → pristine
BASE_LEDGER_ROWS="$(_ledger_rows "$LEDGER")"

# ════════════════════════════════════════════════════════════════════════════
# 2. SEED — drive the REAL mutators + the REAL pack engine
# ════════════════════════════════════════════════════════════════════════════
_info "seeding ledger via the real mutators"

# service + group + lua-block go through mutator.sh directly. The mutators are
# library functions (no _not_root gate); they manipulate system state (systemctl
# enable / usermod / file write) so they run as ROOT here, but they write the
# ledger to the USER's $HOME (the revert engine reads it as that user). Force the
# ledger HOME so the recorded rows land where `as_user iictl revert-all` reads.
seed_as_root() {
  # shellcheck source=/dev/null
  HOME="$USER_HOME" XDG_STATE_HOME="$USER_HOME/.local/state" \
    bash -c '
      set -u
      source "'"$II_LIB"'/mutator.sh"
      ii_service_enable "'"$DUMMY_UNIT"'"      || exit 11
      ii_group_add      "'"$TESTUSER"'" "'"$TESTGROUP"'" || exit 12
      printf "%s\n" "hl.exec_cmd(\"true # ii e2e marker\")" \
        | ii_lua_block_write "'"$LUA_FILE"'" "'"$LUA_NAME"'" || exit 13
    '
}
if seed_as_root; then
  _pass "mutators applied (service enable / group add / fenced lua write)"
else
  _fail "seeding via mutators failed (rc=$?)"
fi
# the ledger file is created under root's invocation but lives in the user's HOME;
# make sure the user owns its state tree so `as_user iictl revert-all` can prune it.
chown -R "$TESTUSER":"$TESTUSER" "$USER_HOME/.local" "$USER_HOME/.config" 2>/dev/null || true

# pack: drive the REAL engine as the user. The demo pack's members are small
# OFFICIAL-repo CLIs (sl, cowsay), so `pacman -S` reaches the public mirrors —
# this step needs network (the CI runner and the maintainer's bake host both
# have it). A failure here is reported and fails the test rather than being
# silently skipped, so an offline run is loud, not a false green.
PACK_TESTED=skipped
# Refresh the sync db FIRST. The throwaway --volatile=overlay container starts
# from the pacstrapped base whose /var/lib/pacman/sync is unpopulated for this
# session, and the pack engine classifies each member official-vs-AUR with
# `pacman -Si <m>` (iictl.d/pack): an empty db misclassifies the official demo
# members (sl, cowsay — both in [extra]) as AUR and triggers a paru bootstrap
# that needs base-devel (absent in the minimal base). A successful `pacman -Sy`
# makes `pacman -Si` resolve them as official so they install via `pacman -S`
# with NO AUR path. (Setup-only; the pack engine itself is unchanged.) We run as
# root here (the in-container payload is root before any as_user call).
_info "refreshing pacman sync db so the pack engine classifies members correctly"
if pacman -Sy --noconfirm; then
  _pass "pacman sync db refreshed (sl/cowsay now classify as official)"
else
  _fail "pacman -Sy failed — pack member classification will fall back to AUR"
fi
# NB: do NOT `pacman -Sy archlinux-keyring` here — its post-install hook runs
# pacman-key --populate → gpg, and the throwaway box's gpg-agent is flaky (the
# pacstrap "gpg-agent unusable" warnings), so that upgrade can HANG. pacstrap
# already imported archlinux-keyring, so signature checks on the [extra] members
# work without touching it.

_info "installing pack '$PACK' (real iictl pack engine; needs network)"
if as_user iictl pack install "$PACK"; then
  PACK_TESTED=engine
  _pass "iictl pack install $PACK (online)"
else
  _fail "iictl pack install $PACK failed (no network?) — the kind=pack inverse cannot be exercised"
fi

# Snapshot AFTER seeding so we can prove the deltas are real (not no-ops).
SEED_SVC="$(systemctl is-enabled "$DUMMY_UNIT" 2>/dev/null || echo disabled)"
SEED_GRP_MEMBER=no; id -nG "$TESTUSER" 2>/dev/null | tr ' ' '\n' | grep -qx "$TESTGROUP" && SEED_GRP_MEMBER=yes
SEED_LUA_SHA="$(sha256sum "$LUA_FILE" | cut -d' ' -f1)"
SEED_LEDGER_ROWS="$(_ledger_rows "$LEDGER")"

_check "service was actually enabled by seed"        "enabled" "$SEED_SVC"
_check "group membership was actually added by seed"  "yes"     "$SEED_GRP_MEMBER"
[[ "$SEED_LUA_SHA" != "$BASE_LUA_SHA" ]] \
  && _pass "custom/general.lua was actually modified by the fence write" \
  || _fail "fence write did not change custom/general.lua (idempotent no-op?)"
# fence content sanity: our named block must be present and properly delimited.
grep -qF -- "-- >>> illogical-impulse $LUA_NAME" "$LUA_FILE" \
  && grep -qF -- "-- <<< illogical-impulse $LUA_NAME" "$LUA_FILE" \
  && _pass "named sentinel fence present in custom/general.lua" \
  || _fail "sentinel fence missing/malformed in custom/general.lua"
(( SEED_LEDGER_ROWS > BASE_LEDGER_ROWS )) \
  && _pass "ledger grew during seed ($BASE_LEDGER_ROWS → $SEED_LEDGER_ROWS rows)" \
  || _fail "ledger did not grow during seed (no reversible actions recorded?)"

# ════════════════════════════════════════════════════════════════════════════
# 3. DRY RUN — must plan everything and change NOTHING
# ════════════════════════════════════════════════════════════════════════════
_info "iictl revert-all --dry-run (must touch nothing)"
DRY_SVC_BEFORE="$SEED_SVC"
as_user iictl revert-all --deep --dry-run >/dev/null 2>&1 || _fail "revert-all --dry-run exited non-zero"
DRY_SVC_AFTER="$(systemctl is-enabled "$DUMMY_UNIT" 2>/dev/null || echo disabled)"
DRY_LUA_SHA="$(sha256sum "$LUA_FILE" | cut -d' ' -f1)"
DRY_LEDGER_ROWS="$(_ledger_rows "$LEDGER")"
_check "dry-run left service untouched" "$DRY_SVC_BEFORE" "$DRY_SVC_AFTER"
_check "dry-run left custom/general.lua untouched" "$SEED_LUA_SHA" "$DRY_LUA_SHA"
_check "dry-run left the ledger untouched (no rows pruned)" "$SEED_LEDGER_ROWS" "$DRY_LEDGER_ROWS"

# ════════════════════════════════════════════════════════════════════════════
# 4. REAL REVERT — restore vanilla
# ════════════════════════════════════════════════════════════════════════════
_info "iictl revert-all --deep (the real round-trip)"
# --deep so an install-classified row (e.g. a docker group, were one present) is
# also in scope; our seeded rows are ordinary iictl-time choices, but --deep is
# a superset and proves the broadest restore. iictl not having a graphical
# `doctor`-clean system in the container is fine — doctor warnings don't fail it.
as_user iictl revert-all --deep --force >/dev/null 2>&1
REVERT_RC=$?
# revert-all returns non-zero only if an inverse FAILED; a clean run is 0.
(( REVERT_RC == 0 )) \
  && _pass "revert-all completed with no failed inverses (rc=0)" \
  || _fail "revert-all reported failed inverse(s) (rc=$REVERT_RC)"

# ════════════════════════════════════════════════════════════════════════════
# 5. ASSERT VANILLA RETURNED — byte-for-byte against the pristine baseline
# ════════════════════════════════════════════════════════════════════════════
_info "asserting the system matches the pristine baseline"

POST_SVC="$(systemctl is-enabled "$DUMMY_UNIT" 2>/dev/null || echo disabled)"
_check "service enabled-state restored to baseline" "$BASE_SVC" "$POST_SVC"

POST_GRP_MEMBER=no; id -nG "$TESTUSER" 2>/dev/null | tr ' ' '\n' | grep -qx "$TESTGROUP" && POST_GRP_MEMBER=yes
_check "group membership restored to baseline" "$BASE_GRP_MEMBER" "$POST_GRP_MEMBER"

POST_LUA_SHA="$(sha256sum "$LUA_FILE" | cut -d' ' -f1)"
_check "custom/general.lua restored BYTE-FOR-BYTE to baseline" "$BASE_LUA_SHA" "$POST_LUA_SHA"
# explicit: the fence is gone but the user's stub lines survive.
grep -qF -- "illogical-impulse $LUA_NAME" "$LUA_FILE" \
  && _fail "sentinel fence still present after revert (block not stripped)" \
  || _pass "sentinel fence fully stripped after revert"
grep -qF -- "user lines live here and must survive a revert untouched" "$LUA_FILE" \
  && _pass "user's own custom/general.lua lines survived the revert" \
  || _fail "revert clobbered the user's own custom/general.lua lines"

# pack: the recorded set must be gone — assert at the member level (a pack is a
# name-list, not a package; revert does an exact `pacman -Rns` of the resolved
# set the ledger recorded).
if [[ "$PACK_TESTED" == engine ]]; then
  # members the seed added (i.e. weren't present at baseline) must be gone again.
  pack_member_residue=0
  for m in "${PACK_MEMBERS[@]}"; do
    was_present=no
    for b in "${BASE_MEMBERS_PRESENT[@]:-}"; do [[ "$b" == "$m" ]] && was_present=yes; done
    if [[ "$was_present" == no ]] && pacman -Qq "$m" >/dev/null 2>&1; then
      pack_member_residue=$((pack_member_residue+1))
      _fail "pack member '$m' added by seed is still installed after revert"
    fi
  done
  (( pack_member_residue == 0 )) && _pass "every pack member added by the seed was removed by revert"
else
  _info "pack inverse not asserted (install was skipped/failed)"
fi

# the ledger must be drained back to its pristine row count (everything pruned).
POST_LEDGER_ROWS="$(_ledger_rows "$LEDGER")"
_check "ledger drained back to baseline row count" "$BASE_LEDGER_ROWS" "$POST_LEDGER_ROWS"

# ── verdict ──────────────────────────────────────────────────────────────────
echo
if (( FAIL == 0 )); then
  printf '%s== Iron Law round-trip: PASS ==%s  (%d assertions)\n' "$C_G$C_B" "$C_0" "$PASS"
  exit 0
else
  printf '%s== Iron Law round-trip: FAIL ==%s  (%d ok, %d failed)\n' "$C_R$C_B" "$C_0" "$PASS" "$FAIL"
  exit 1
fi
