-- /etc/skel-live/.config/hypr/custom/keybinds.lua
--
-- LIVE-ISO-ONLY keybindings. Loaded by end4's hyprland.lua via
-- `require("custom.keybinds")` (single-file slot — hyprland.lua does not
-- glob this directory, so to add a binding without losing upstream's we
-- must include both in this file).
--
-- Upstream's stock dots/.config/hypr/custom/keybinds.lua only contains
-- the "edit-keybinds" shortcut below; we mirror it here verbatim so the
-- live ISO behaves identically to a fresh install plus our installer key.

-- ── Upstream stock (verbatim from dots/.config/hypr/custom/keybinds.lua) ──
hl.bind("CTRL+SUPER+ALT+Slash",
    hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"),
    {description = "Edit user keybinds"})

-- ── Live-ISO addition ────────────────────────────────────────────────────
hl.bind("SUPER + I",
    hl.dsp.exec_cmd("/usr/local/bin/ii-launch-installer"),
    { description = "Live ISO: Launch Illogical Impulse installer" })
