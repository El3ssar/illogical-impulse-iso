-- /etc/skel-live/.config/hypr/custom/execs.lua
--
-- LIVE-ISO-ONLY Hyprland exec hook. Loaded by upstream's hyprland.lua via
-- `require("custom.execs")`. Ships only to liveuser via /etc/skel-live;
-- the installed system's first user never sees it.
--
-- Behaviour:
--   * Kernel cmdline contains `ii_autoinstall` (the install-smoke harness,
--     TEST-01) → run the UNATTENDED Calamares driver (ii-autoinstall): it
--     overlays a scripted config from the seed disk, installs headlessly, and
--     powers the VM off. Live-only; checked first so the smoke never falls
--     through to the interactive installer.
--   * Kernel cmdline contains `ii_install` (the "Install Illogical
--     Impulse" boot entry) → wait for the rice to settle, auto-launch
--     Calamares.
--   * Otherwise ("Try" boot) → raise the ii-live-welcome notification:
--     a persistent, dismissible "install me" entry point rendered by the
--     rice's own notification UI. Quickshell has no desktop icons, so
--     without this the installer is only findable via launcher search.
--     Super+I (custom/keybinds.lua) remains the quiet fallback.

hl.on("hyprland.start", function()
    local function read_file(path)
        local f = io.open(path, "r")
        if not f then return "" end
        local s = f:read("*a")
        f:close()
        return s or ""
    end

    local cmdline = read_file("/proc/cmdline")
    local autoinstall = cmdline:match("ii_autoinstall") ~= nil
    local install_only = cmdline:match("ii_install") ~= nil

    if autoinstall then
        -- Unattended install smoke (TEST-01): drive Calamares from a scripted
        -- seed config, then power off. Same ~4s settle as the interactive path.
        hl.exec_cmd("sleep 4 && /usr/local/bin/ii-autoinstall")
    elseif install_only then
        -- Give the rice (Quickshell, polkit agent, ydotool) ~4s to come
        -- up so Calamares' Qt window has its dependencies in place.
        hl.exec_cmd("sleep 4 && /usr/local/bin/ii-launch-installer")
    else
        hl.exec_cmd("/usr/local/bin/ii-live-welcome")
    end
end)
