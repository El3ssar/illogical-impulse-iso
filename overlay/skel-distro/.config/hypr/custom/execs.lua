-- ~/.config/hypr/custom/execs.lua — user-editable exec hooks (upstream
-- ships this file empty; it is YOURS to change).
--
-- ── Illogical Impulse ISO addition ──────────────────────────────────────
-- One-time distro welcome card. Upstream's own welcome app owns the first
-- login; this shows on the next one, then never again (markers in
-- ~/.local/state). Reopen anytime: `iictl welcome`. Delete this block
-- freely if you don't want it.
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/local/bin/iictl welcome --auto")
end)
