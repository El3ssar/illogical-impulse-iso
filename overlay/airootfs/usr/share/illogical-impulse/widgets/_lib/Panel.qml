// Illogical Impulse widget framework — reusable layer-shell Panel base (issue #20).
//
// A themed wlr-layer-shell surface every widget composes (Panel + Theme). It is a
// Quickshell PanelWindow (the wlr-layer-shell window type) with a rounded themed
// card, sane anchoring/margins, and an exclusion-zone hook. Widgets set
// surfaceColor/borderColor from Theme and drop their content inside (the default
// property), e.g.  Panel { surfaceColor: Theme.surface; ColumnLayout { ... } }.
//
// Self-contained: it references no upstream type and no Theme singleton directly
// (the widget wires Theme in), so it is safe to reuse from any standalone config.

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: win

    // Child content goes into the inner padded item.
    default property alias content: inner.data

    // Themable surface knobs (the widget feeds these from Theme).
    property color surfaceColor: "#1E202B"
    property color borderColor: "#3A4154"
    property int radius: 18
    property int pad: 16

    // The window itself is transparent; the rounded card draws the surface.
    color: "transparent"

    // Default placement: a floating top-right card. Widgets may override.
    anchors { top: true; right: true }
    margins { top: 48; right: 24 }
    implicitWidth: 420
    implicitHeight: 560

    // Floating overlay by default — no struts stolen from tiled windows. A widget
    // that wants to reserve space sets exclusiveZone to its width/height.
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "ii-widget"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Rectangle {
        anchors.fill: parent
        anchors.margins: 8
        radius: win.radius
        color: win.surfaceColor
        border.color: win.borderColor
        border.width: 1

        Item {
            id: inner
            anchors.fill: parent
            anchors.margins: win.pad
        }
    }
}
