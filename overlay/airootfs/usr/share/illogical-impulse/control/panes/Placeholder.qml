// Placeholder pane — the shared landing a registry entry points at when its
// domain verb is not yet present. It tries the domain's --spec (so it lights up
// automatically the day the verb lands) and otherwise explains the pane is coming.
// Set `domain` from the registry via the Loader (see shell.qml); when unset it is
// a plain "coming soon" card. Keeps the GUI/verb contract clean either way.
import QtQuick
import QtQuick.Layouts
import ".."
import "../_ui"

Item {
    id: pane
    property string domain: ""
    property string title: "Coming soon"

    // If a domain is given, defer entirely to the generic spec renderer.
    Loader {
        anchors.fill: parent
        active: pane.domain.length > 0
        sourceComponent: SpecForm {
            domain: pane.domain
            heading: pane.title
        }
    }

    // Otherwise, an honest placeholder.
    EmptyState {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 420)
        visible: pane.domain.length === 0
        glyph: "construction"
        message: "This section is on the way. It will appear here as soon as its iictl verb ships — no shell changes needed."
    }
}
