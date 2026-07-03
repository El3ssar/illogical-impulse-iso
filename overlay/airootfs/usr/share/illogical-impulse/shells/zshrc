# ~/.zshrc — Illogical Impulse distro default (themed, self-contained).
#
# Template copied verbatim by `iictl shell set zsh` into the user's UNOWNED
# home-root ~/.zshrc IF one is absent (skel already ships this file for new
# installs; the copy is only for a user who deleted it or came from vanilla).
# Upstream's dots ship NO .zshrc, so this is a COMPLETE config, not an
# append-loader, and is fully reversible: delete it and zsh falls back to the
# bare Arch default. It only *reads* the upstream-generated Material You palette
# and *sources* upstream's zshrc.d snippets read-only; it never writes to or
# edits any upstream-owned path. Contains no identity/PII.

# ── upstream zshrc.d snippets (READ-ONLY source) ──────────────────────────────
# Upstream ships ~/.config/zshrc.d/*.zsh (dots-hyprland.zsh, shortcuts.zsh,
# auto-Hypr.sh) but no .zshrc to source them. We source them read-only so the
# rice's own zsh wiring (its sequences cat, aliases, auto-Hypr) keeps working.
# This directory is upstream rsync --delete territory — we ONLY source it.
if [[ -d "$HOME/.config/zshrc.d" ]]; then
    setopt LOCAL_OPTIONS NULL_GLOB   # unmatched globs expand to nothing, not literally
    for _ii_zrc in "$HOME"/.config/zshrc.d/*.zsh "$HOME"/.config/zshrc.d/*.sh; do
        [[ -r "$_ii_zrc" ]] && source "$_ii_zrc"
    done
    unset _ii_zrc
fi

# ── Material You palette ──────────────────────────────────────────────────────
# Inherit the rice's colors from the upstream-generated terminal sequences,
# exactly as upstream's own config.fish / zshrc.d/dots-hyprland.zsh do. Guarded
# by a file-exists test so it degrades to a no-op when the file is absent
# (pre-first-boot) or if upstream renames the path. Read-only; the path includes
# the terminal/ subdir. (dots-hyprland.zsh above already cats this when present;
# this defensive re-cat covers a box where that snippet is absent.)
_ii_seq="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/terminal/sequences.txt"
[[ -f "$_ii_seq" ]] && cat "$_ii_seq"
unset _ii_seq

# ── antidote plugin manager (guarded — no-op when the manifest is absent) ──────
# antidote loads the curated bundle from the ii-owned manifest
# ~/.config/zsh/ii-plugins.txt (managed by `iictl plugins` / `iictl shell
# plugins`). The load is GUARDED on the manifest's existence so deleting the
# manifest ⇒ vanilla zsh with no plugin machinery. antidote itself is vendored
# to the distro-owned ~/.antidote (skel-distro.fetch) or installed as the
# zsh-antidote package; the source line is guarded so a box without it still
# starts a working shell.
_ii_antidote_home="${ANTIDOTE_HOME:-$HOME/.antidote}"
# The manifest is the ii-owned path #48 writes — always under ~/.config/zsh.
_ii_plugins="$HOME/.config/zsh/ii-plugins.txt"
if [[ -r "$_ii_antidote_home/antidote.zsh" && -r "$_ii_plugins" ]]; then
    source "$_ii_antidote_home/antidote.zsh"
    antidote load "$_ii_plugins"
elif command -v antidote >/dev/null 2>&1 && [[ -r "$_ii_plugins" ]]; then
    # System-installed antidote (zsh-antidote package) exposes the `antidote`
    # function via /usr/share; still guarded on the manifest so no manifest ⇒ no-op.
    autoload -Uz antidote 2>/dev/null || true
    antidote load "$_ii_plugins"
fi
unset _ii_antidote_home _ii_plugins

# ── Prompt ────────────────────────────────────────────────────────────────────
# Respect the ii-prompt selector (default starship; `iictl shell prompt` can
# switch to oh-my-posh). Guarded so an absent prompt tool is inert.
_ii_prompt_sel="$(cat "$HOME/.config/illogical-impulse/ii-prompt" 2>/dev/null || echo starship)"
case "$_ii_prompt_sel" in
    oh-my-posh)
        if command -v oh-my-posh >/dev/null 2>&1; then
            eval "$(oh-my-posh init zsh)"
        elif command -v starship >/dev/null 2>&1; then
            eval "$(starship init zsh)"
        fi
        ;;
    *)
        command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
        ;;
esac
unset _ii_prompt_sel

# ── Modern-CLI aliases & inits (each guarded — inert when a tool is absent) ────
# eza → ls family (mirrors upstream config.fish's `eza --icons`).
if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons'
    alias ll='eza -l --git'
    alias la='eza -la --git'
    alias tree='eza --tree'
fi

# bat → cat (neutral default theme; don't hardcode a flavor that fights matugen).
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'

# ripgrep: intentionally NOT aliased over grep — shadowing grep surprises scripts.

# zoxide → smarter cd.
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# atuin → shell history (opt-in via the dev-toolchain domain; init here if present).
command -v atuin >/dev/null 2>&1 && eval "$(atuin init zsh)"

# carapace → multi-shell completions.
command -v carapace >/dev/null 2>&1 && source <(carapace _carapace zsh)

# fzf key-bindings + completion (Arch ships these under /usr/share/fzf).
[[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
[[ -f /usr/share/fzf/completion.zsh   ]] && source /usr/share/fzf/completion.zsh

# direnv → per-directory env.
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

# ── zsh niceties ──────────────────────────────────────────────────────────────
setopt AUTO_CD INTERACTIVE_COMMENTS
HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_DUPS SHARE_HISTORY
mkdir -p "$(dirname "$HISTFILE")" 2>/dev/null
autoload -Uz compinit && compinit -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump" 2>/dev/null
