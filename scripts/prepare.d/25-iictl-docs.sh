# shellcheck shell=bash disable=SC2154
# 25-iictl-docs — bake iictl(1) man pages from the #help: headers that the
# CLI and its iictl.d/ plugins already carry. Runs AFTER 20-airootfs.sh has
# staged usr/local/bin/iictl + usr/local/lib/ii/iictl.d/* into build/airootfs.
#
# Build-time generation (not install time) so the .gz ships baked in the
# squashfs and lands on the installed system unchanged. No external doc
# toolchain: the roff is emitted with plain printf, consistent with the
# project's dependency-light ethos.
#
# Additive + reversible: the only outputs are deletable .gz files under our own
# /usr/share/man/man1/iictl*.1.gz; removing them un-mans iictl with no residue.
# The #help: headers are the single source of truth shared with iictl help and
# the shell completions.

IICTL="$BUILD/airootfs/usr/local/bin/iictl"
IICTL_D="$BUILD/airootfs/usr/local/lib/ii/iictl.d"
MAN1="$BUILD/airootfs/usr/share/man/man1"

step "bake iictl(1) man pages from #help: headers"

[[ -f "$IICTL" ]] || die "iictl not staged at $IICTL — run 20-airootfs.sh first"

install -d "$MAN1"

# Roff-escape a description line: backslash, and leading-dot/quote guard.
_roff_escape() {
  local s=$1
  s=${s//\\/\\\\}
  printf '%s' "$s"
}

# Read a file's #help: lines as "verb<TAB>desc" pairs (sep = tab or runs of
# spaces). Emits one "verb<TAB>desc" line per #help: header.
_help_pairs() {
  grep -E '^#help:[[:space:]]' "$1" 2>/dev/null \
    | sed -E 's/^#help:[[:space:]]*//' \
    | awk '{ verb=$1; $1=""; sub(/^[ \t]+/,""); printf "%s\t%s\n", verb, $0 }'
}

DATE_HUMAN="$(date -u +%Y-%m-%d)"

# --- Top-level iictl.1: synopsis + grouped command list ----------------------
{
  printf '.TH IICTL 1 "%s" "Illogical Impulse" "Illogical Impulse Manual"\n' "$DATE_HUMAN"
  printf '.SH NAME\n'
  printf 'iictl \\- Illogical Impulse distro control CLI\n'
  printf '.SH SYNOPSIS\n'
  printf '.B iictl\n'
  printf '[\\fICOMMAND\\fR] [\\fIARGS\\fR]\n'
  printf '.SH DESCRIPTION\n'
  printf 'Strictly additive control CLI for the Illogical Impulse distribution.\n'
  printf 'It drives the upstream dotfiles updater the supported way and never\n'
  printf 'patches the rice. Verbs come in two kinds: inline built-ins and drop-in\n'
  printf 'plugins discovered at \\fI/usr/local/lib/ii/iictl.d/\\fR. Running\n'
  printf '.B iictl\n'
  printf 'with no command opens the distro welcome card.\n'
  printf '.SH CORE COMMANDS\n'
  while IFS=$'\t' read -r verb desc; do
    [[ -n "$verb" ]] || continue
    printf '.TP\n.B %s\n%s\n' "$verb" "$(_roff_escape "$desc")"
  done < <(_help_pairs "$IICTL")
  # Plugin commands, each with its own iictl-<verb>.1 page.
  if [[ -d "$IICTL_D" ]]; then
    _printed_hdr=0
    for p in "$IICTL_D"/*; do
      [[ -f "$p" && -x "$p" ]] || continue
      while IFS=$'\t' read -r verb desc; do
        [[ -n "$verb" ]] || continue
        if (( _printed_hdr == 0 )); then printf '.SH FEATURE COMMANDS (PLUGINS)\n'; _printed_hdr=1; fi
        printf '.TP\n.B %s\n%s (see \\fBiictl\\-%s\\fR(1))\n' "$verb" "$(_roff_escape "$desc")" "$verb"
        break  # one #help: line per plugin
      done < <(_help_pairs "$p")
    done
  fi
  printf '.SH FILES\n'
  printf '.TP\n.I /usr/local/bin/iictl\nThe CLI itself (survives install).\n'
  printf '.TP\n.I /usr/local/lib/ii/iictl.d/\nDrop-in plugin verbs, one file per feature.\n'
  printf '.SH SEE ALSO\n'
  _sa=()
  if [[ -d "$IICTL_D" ]]; then
    for p in "$IICTL_D"/*; do
      [[ -f "$p" && -x "$p" ]] || continue
      _sa+=("\\fBiictl\\-$(basename "$p")\\fR(1)")
    done
  fi
  if (( ${#_sa[@]} > 0 )); then
    printf '%s\n' "$(IFS=', '; printf '%s' "${_sa[*]}")"
  else
    printf 'fish(1), bash(1), zsh(1)\n'
  fi
} > "$MAN1/iictl.1"
gzip -9nf "$MAN1/iictl.1"

# --- Per-plugin iictl-<verb>.1 ------------------------------------------------
_pages=1
if [[ -d "$IICTL_D" ]]; then
  for p in "$IICTL_D"/*; do
    [[ -f "$p" && -x "$p" ]] || continue
    verb="$(basename "$p")"
    desc=""
    while IFS=$'\t' read -r v d; do
      [[ -n "$v" ]] || continue
      desc="$d"; break
    done < <(_help_pairs "$p")
    [[ -n "$desc" ]] || desc="iictl $verb plugin"
    {
      printf '.TH IICTL\\-%s 1 "%s" "Illogical Impulse" "Illogical Impulse Manual"\n' "$verb" "$DATE_HUMAN"
      printf '.SH NAME\n'
      printf 'iictl\\-%s \\- %s\n' "$verb" "$(_roff_escape "$desc")"
      printf '.SH SYNOPSIS\n'
      printf '.B iictl %s\n' "$verb"
      printf '[\\fIARGS\\fR]\n'
      printf '.SH DESCRIPTION\n'
      printf '%s\n' "$(_roff_escape "$desc")"
      printf '.PP\n'
      printf 'This is an \\fBiictl\\fR feature command (a drop-in plugin at\n'
      printf '\\fI/usr/local/lib/ii/iictl.d/%s\\fR). Run it as\n' "$verb"
      printf '.BR "iictl %s" .\n' "$verb"
      printf '.SH SEE ALSO\n'
      printf '\\fBiictl\\fR(1)\n'
    } > "$MAN1/iictl-$verb.1"
    gzip -9nf "$MAN1/iictl-$verb.1"
    _pages=$((_pages + 1))
  done
fi

ok "baked $_pages man page(s) → usr/share/man/man1/iictl*.1.gz"
