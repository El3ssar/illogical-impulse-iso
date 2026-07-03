# ~/.zshenv — Illogical Impulse distro default (zsh environment).
#
# Template copied verbatim by `iictl shell set zsh` into the UNOWNED home-root
# ~/.zshenv IF absent. Upstream ships none, so this is a complete, reversible
# file (delete it → vanilla). Sourced for EVERY zsh (login/interactive/script),
# so keep it to environment only — no prompts, no plugin loads, no output.
# Contains no identity/PII.

# XDG base dirs (only set if unset, so a user override wins).
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# antidote home (distro-owned; the vendored/installed plugin manager lives here).
export ANTIDOTE_HOME="${ANTIDOTE_HOME:-$HOME/.antidote}"
