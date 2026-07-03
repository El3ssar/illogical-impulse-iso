// NavRailButton — one entry in the left navigation rail: a Material Symbols icon
// over a label, with a selected pill, hover, and a keyboard focus ring. A real
// Button (Space/Enter activate, Tab focuses). The shell builds the rail by
// repeating this over the pane registry — no rail entry is hand-wired.
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Button {
    id: nav
    property string glyph: "tune"
    property bool selected: false
    implicitWidth: 76
    implicitHeight: 62
    padding: 0
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true

    background: Rectangle {
        radius: 14
        anchors.fill: parent
        anchors.margins: 4
        color: nav.selected ? Qt.alpha(Colors.primary, 0.16)
             : (nav.hovered ? Colors.surfaceHigh : "transparent")
        border.color: nav.activeFocus ? Colors.primary : "transparent"
        border.width: nav.activeFocus ? 2 : 0
        Behavior on color { ColorAnimation { duration: 110 } }
    }

    contentItem: ColumnLayout {
        spacing: 3
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: nav.glyph
            font.family: "Material Symbols Rounded"
            font.pixelSize: 22
            color: nav.selected ? Colors.primary : Colors.onSurfaceVariant
            Behavior on color { ColorAnimation { duration: 110 } }
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            text: nav.text
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            font.pixelSize: 10
            font.bold: nav.selected
            color: nav.selected ? Colors.primary : Colors.onSurfaceVariant
        }
    }
}
