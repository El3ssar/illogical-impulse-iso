# ii-aliases.fish — Illogical Impulse fish aliases (excluded-from-sync slot).
#
# Lives in ~/.config/fish/conf.d/ (the --exclude=conf.d slot 30-skel.sh keeps).
# Additive convenience aliases only — each guarded on the underlying tool so it
# is inert when absent. Upstream's config.fish already sets `ls → eza --icons`;
# we DON'T redefine ls (avoid fighting upstream), only add the extra family and
# a couple of universally-handy ones. Contains no identity/PII; touches no
# upstream-owned path.

if status is-interactive
    if type -q eza
        alias ll 'eza -l --git'
        alias la 'eza -la --git'
        alias lt 'eza --tree'
    end

    # bat → cat (neutral theme; no hardcoded flavor that fights matugen).
    if type -q bat
        alias cat 'bat --paging=never'
    end
end
