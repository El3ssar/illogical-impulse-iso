-- ~/.config/hypr/custom/execs.lua — user-editable exec hooks (upstream
-- ships this file empty; it is YOURS to change).
--
-- >>> illogical-impulse welcome
-- ── Illogical Impulse ISO addition ──────────────────────────────────────
-- One-time distro welcome card. Upstream's own welcome app owns the first
-- login; this shows on the next one, then never again (markers in
-- ~/.local/state). Reopen anytime: `iictl welcome`. Delete this block
-- freely — everything between the `>>>` / `<<<` sentinels, or run
-- `iictl revert-all` — if you don't want it.
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/local/bin/iictl welcome --auto")
end)
-- <<< illogical-impulse welcome
