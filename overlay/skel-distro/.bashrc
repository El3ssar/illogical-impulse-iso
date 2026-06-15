# ~/.bashrc — Illogical Impulse distro default (themed, self-contained).
#
# Lives in the UNOWNED home-root seam: upstream's dots ship no .bashrc, so this
# is a COMPLETE replacement (not an append-loader) and is fully reversible —
# delete it and the new user's bash falls back to Arch's bare skel. It only
# *reads* the upstream-generated Material You palette; it never writes to or
# sources any upstream-owned path. Contains no identity/PII.

# If not running interactively, do nothing.
[[ $- != *i* ]] && return

# ── Material You palette ──────────────────────────────────────────────────
# Inherit the rice's colors from the upstream-generated terminal sequences,
# exactly as upstream's own config.fish / zshrc.d do. Guarded by a file-exists
# test so it degrades to a no-op when the file is absent (pre-first-boot) or if
# upstream renames the path. Read-only; the path includes the terminal/ subdir.
_ii_seq="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/terminal/sequences.txt"
[[ -f "$_ii_seq" ]] && cat "$_ii_seq"
unset _ii_seq

# ── Prompt ────────────────────────────────────────────────────────────────
command -v starship >/dev/null && eval "$(starship init bash)"

# ── Modern-CLI aliases & inits (each guarded — inert when a tool is absent) ─
# eza → ls family (mirrors upstream config.fish's `eza --icons`).
if command -v eza >/dev/null; then
    alias ls='eza --icons'
    alias ll='eza -l --git'
    alias la='eza -la --git'
    alias tree='eza --tree'
fi

# bat → cat (neutral default theme; don't hardcode a flavor that fights matugen).
command -v bat >/dev/null && alias cat='bat --paging=never'

# ripgrep: intentionally NOT aliased over grep — shadowing grep surprises
# scripts. Use `rg` directly.

# zoxide → smarter cd.
command -v zoxide >/dev/null && eval "$(zoxide init bash)"

# fzf key-bindings + completion (Arch ships these under /usr/share/fzf).
[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash   ]] && source /usr/share/fzf/completion.bash

# direnv → per-directory env.
command -v direnv >/dev/null && eval "$(direnv hook bash)"
