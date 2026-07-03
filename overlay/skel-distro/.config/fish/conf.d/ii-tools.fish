# ii-tools.fish — Illogical Impulse modern-CLI inits for fish (excluded slot).
#
# Lives in ~/.config/fish/conf.d/ (the --exclude=conf.d slot 30-skel.sh keeps —
# survives `iictl update`, never collides with upstream's config.fish). Each init
# is GUARDED on the tool being installed, so this is a no-op on a box that lacks
# the tool. The dev-toolchain domain (mise/zoxide/atuin) places its activation
# lines ONLY in ii-owned files like this one — never in upstream's config.fish.
# Contains no identity/PII; touches no upstream-owned path.

if status is-interactive
    # zoxide → smarter cd.
    if type -q zoxide
        zoxide init fish | source
    end

    # atuin → shell history.
    if type -q atuin
        atuin init fish | source
    end

    # carapace → multi-shell completions.
    if type -q carapace
        carapace _carapace fish | source
    end

    # direnv → per-directory env.
    if type -q direnv
        direnv hook fish | source
    end
end
