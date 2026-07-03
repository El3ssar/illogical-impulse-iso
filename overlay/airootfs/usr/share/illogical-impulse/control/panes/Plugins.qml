// Plugins pane — drives `iictl plugins` (issue #48): manage zsh plugins from
// multiple sources (antidote / Oh My Zsh / raw git). The chooser renderer shows
// the enabled set (removable) and, per source, browsable candidates to add.
import QtQuick
import "../_ui"

SpecForm {
    domain: "plugins"
    heading: "Plugins"
    blurb: "Manage zsh plugins from antidote, Oh My Zsh, or raw git. Pick a source and browse candidates to add; changes are written to the distro-owned plugin manifest and are reversible."
}
