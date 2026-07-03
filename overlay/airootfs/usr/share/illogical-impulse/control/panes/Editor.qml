// Editor pane — drives `iictl nvim` (issue #17): pick a Neovim distro (LazyVim,
// AstroNvim, NvChad, kickstart, plain) reversibly. The baked default is vanilla
// nvim; a pick clones the distro online at a pinned rev, stamped + ledger-recorded.
import QtQuick
import "../_ui"

SpecForm {
    domain: "nvim"
    heading: "Editor"
    blurb: "Choose a Neovim configuration. The default is a bare vanilla nvim; a pick clones a distro online at a pinned revision and is fully reversible (iictl nvim restore / revert-all returns to bare)."
}
