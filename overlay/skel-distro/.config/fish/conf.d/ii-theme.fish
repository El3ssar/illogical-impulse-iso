# ii-theme.fish — Illogical Impulse fish theming (excluded-from-sync slot).
#
# ~/.config/fish/conf.d/ is the ONE fish slot that survives `iictl update`:
# 30-skel.sh rsyncs upstream fish with `--exclude=conf.d`, so our ii-*.fish files
# here are never wiped and never collide with upstream's config.fish (which we
# NEVER edit). This file is a defensive re-source of the Material You palette
# from the EXACT upstream-generated generated/terminal/sequences.txt path — the
# same path upstream's own config.fish:16 cats — so colors apply even on a box
# where upstream's snippet did not run. Guarded on the file's existence so it is
# a no-op pre-first-boot or if upstream renames the path. Read-only; contains no
# identity/PII; touches no upstream-owned path.

if status is-interactive
    set -l ii_seq "$HOME/.local/state/quickshell/user/generated/terminal/sequences.txt"
    if set -q XDG_STATE_HOME
        set ii_seq "$XDG_STATE_HOME/quickshell/user/generated/terminal/sequences.txt"
    end
    if test -f "$ii_seq"
        cat "$ii_seq"
    end
end
