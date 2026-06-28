# nvidia-classify.sh — pure NVIDIA driver-variant classifier (no I/O, no state).
#
# Sourced by ii-post-install at install time to map an NVIDIA PCI device id to
# the driver variant we should install. Kept pure (functions only; reads no
# files, writes nothing, runs nothing on source) so it is unit-testable in
# isolation — see the HW-01 test table in validate.sh, which exercises the
# Turing/Pascal/Kepler boundary ids so a boundary regression fails CI.
#
# The heuristic: supported-gpus.json no longer ships anywhere, so we classify by
# PCI device id alone. NVIDIA device ids grow (roughly) monotonically per
# generation, which lets two range boundaries separate the three driver worlds:
#
#   id >= 0x1E00          Turing and newer (TU102+)   → nvidia-open-dkms ("open")
#   0x1300 <= id < 0x1E00 Maxwell / Pascal / Volta     → nvidia-580xx     ("legacy")
#   id <  0x1300          Kepler and older            → nouveau           ("nouveau")
#
# FAILURE MODE / ASSUMPTION: the ranges assume NVIDIA never reuses an id from an
# older generation above a newer generation's floor. If NVIDIA ships a new GPU
# whose id falls in the wrong band (or back-fills an old band), this misclassifies
# and installs the wrong driver (or nouveau) for that whole id neighbourhood.
# That is exactly the regression the HW-01 boundary test table guards: when the
# bands move, update both the constants below AND the table in one change.
#
# This lib is install-time-only but defines no side effects, so it is safe to
# leave on disk after install (it is a deletable, stateless function library —
# the Iron Law's "additive + reversible" holds trivially).

# Band boundaries — the single source of truth for the classifier. Decimal so the
# arithmetic below needs no base prefixes; keep in sync with the doc block above
# and the validate.sh HW-01 table.
II_NV_OPEN_FLOOR=$((16#1E00))     # >= this id → open
II_NV_LEGACY_FLOOR=$((16#1300))   # >= this id (and < open floor) → legacy

# ii_nvidia_classify <device-id> → echoes open|legacy|nouveau; rc 0 on a parsed
# id, rc 2 on an unparseable argument (echoes nouveau as the safe default).
# <device-id> may be hex ("0x1e30", "1E30") or already decimal — anything
# bash can read as base-16 once the optional 0x is stripped.
ii_nvidia_classify() {
  local raw="${1-}" id
  raw="${raw#0x}"; raw="${raw#0X}"
  # Reject empty / non-hex input rather than letting bash arithmetic error out.
  if [[ -z "$raw" || ! "$raw" =~ ^[0-9a-fA-F]+$ ]]; then
    echo nouveau
    return 2
  fi
  id=$((16#$raw))
  if   (( id >= II_NV_OPEN_FLOOR ));   then echo open
  elif (( id >= II_NV_LEGACY_FLOOR )); then echo legacy
  else echo nouveau
  fi
}

# ii_nvidia_fold <id...> → echoes the variant to install for a whole machine.
# Mirrors ii-post-install's original precedence exactly: any legacy-class GPU
# forces legacy (the 580xx driver also drives Turing+, but the open driver
# cannot drive pre-Turing at all); else any open-class GPU → open; else nouveau
# (i.e. "none" to install). Returns: open|legacy|nouveau.
ii_nvidia_fold() {
  local id variant chosen=nouveau
  for id in "$@"; do
    variant="$(ii_nvidia_classify "$id")"
    case "$variant" in
      legacy) echo legacy; return 0 ;;   # legacy wins outright
      open)   chosen=open ;;             # remember, but a later legacy still wins
    esac
  done
  echo "$chosen"
}
