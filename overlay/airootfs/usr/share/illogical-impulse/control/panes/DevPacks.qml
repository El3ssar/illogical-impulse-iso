// Dev Packs pane — drives `iictl pack` (issues #6/#19/#25): install/remove curated
// optional software packs (language toolchains, containers, gaming, creative,
// security, virt, backup, flatpak…) ONLINE (official repos + AUR). Never baked;
// each pack is recorded so `iictl pack remove` / `revert-all` peels it cleanly.
import QtQuick
import "../_ui"

SpecForm {
    domain: "pack"
    heading: "Dev Packs"
    blurb: "Install or remove curated software packs online (official repos + AUR via paru). Nothing is baked into the ISO; every pack is recorded and fully reversible. AUR builds can take a while — the console streams live output."
}
