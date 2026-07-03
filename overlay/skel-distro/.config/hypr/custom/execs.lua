
-- >>> illogical-impulse welcome
-- ── Illogical Impulse ISO addition ──────────────────────────────────────
-- ~/.config/hypr/custom/execs.lua — user-editable exec hooks. Upstream ships
-- this file EMPTY; everything below is the distro's, wrapped in this sentinel
-- fence so it stays cleanly removable.
--
-- One-time distro welcome card. Ours OWNS the first login (upstream's own
-- welcome is suppressed by the pre-seeded first_run.txt marker), sets the
-- default wallpaper, then never shows again (marker in ~/.local/state).
-- Reopen anytime: `iictl welcome`.
--
-- Reversible: delete everything between the `>>>` / `<<<` sentinels (or run
-- `iictl revert-all`) and this file returns BYTE-FOR-BYTE to upstream's empty
-- stub — the leading blank line above the fence IS that stub, so nothing
-- distro-authored must ever live outside the fence (validate.sh enforces it).
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/local/bin/iictl welcome --auto")
end)
-- <<< illogical-impulse welcome
-- >>> illogical-impulse theme-feeder
-- ── Illogical Impulse ISO addition — Material You FEEDER (#26) ────────────
-- OPT-IN and DISABLED by default. The exec line below is COMMENTED so nothing
-- runs until the user opts in with `iictl theme feeder enable`, which rewrites
-- THIS fenced block (via the shared ii_lua_block_write mutator, ledger-recorded)
-- to an ACTIVE exec that launches the debounced recolour hook. `iictl theme
-- feeder disable` (or `iictl revert-all`) strips the fence again. This is a
-- SEPARATE fence from the welcome block above; both strip cleanly to upstream's
-- empty stub, so revert-all restores vanilla byte-for-byte.
--
-- The hook runs a STANDALONE matugen against upstream's FINISHED colours.json
-- (read-only) + OUR separate config — it NEVER touches upstream's matugen
-- config.toml or any rsync --delete tree.
-- hl.on("hyprland.start", function()
--     hl.exec_cmd("$HOME/.config/hypr/custom/scripts/ii-theme-feeder.sh --watch")
-- end)
-- <<< illogical-impulse theme-feeder
