
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
