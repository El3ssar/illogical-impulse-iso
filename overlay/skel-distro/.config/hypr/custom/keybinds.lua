hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Edit user keybinds"} )
-- >>> illogical-impulse control-center
-- Illogical Impulse Control Center (issue #14) — the distro configurator GUI.
-- DISTINCT from upstream's Super+I rice settings; this complements it. The whole
-- file replaces upstream's single-line stub because the slot is a single-file
-- `require("custom.keybinds")` (NOT globbed), so the stock edit-keybinds bind is
-- reproduced verbatim above. Reversible: `iictl revert-all` (recorded as a
-- `lua-block` row by ii-post-install) or `ii_lua_block_remove control-center`
-- strips exactly this fence, leaving upstream's stock stub above byte-for-byte.
-- Keys audited-before-reserved (#20 lesson): SUPER+SHIFT+I is free (upstream binds
-- only SUPER+I → rice settings); SUPER+ALT+C for the hub because upstream already
-- binds SUPER+ALT+Space to Window Float/Tile (issue #14's "unbound" claim is stale).
hl.bind("SUPER+SHIFT+I", hl.dsp.exec_cmd("iictl center"), {description = "Open the Illogical Impulse Control Center"})
hl.bind("SUPER+ALT+C", hl.dsp.exec_cmd("iictl center"), {description = "Open the Illogical Impulse Control Center (hub)"})
-- <<< illogical-impulse control-center
