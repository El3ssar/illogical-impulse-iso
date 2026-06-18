-- ~/.config/hypr/custom/execs.lua — user-editable exec hooks (upstream
-- ships this file empty; it is YOURS to change).
--
-- >>> illogical-impulse welcome
-- ── Illogical Impulse ISO addition ──────────────────────────────────────
-- One-time distro welcome card. Ours OWNS the first login (upstream's own
-- welcome is suppressed by the pre-seeded first_run.txt marker), sets the
-- default wallpaper, then never shows again (marker in ~/.local/state).
-- Reopen anytime: `iictl welcome`. Delete this block freely — everything
-- between the `>>>` / `<<<` sentinels, or run `iictl revert-all` — if you
-- don't want it.
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/local/bin/iictl welcome --auto")
end)
-- <<< illogical-impulse welcome
