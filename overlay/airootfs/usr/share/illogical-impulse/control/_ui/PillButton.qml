// PillButton — the app's primary action control (the welcome/Packages pill,
// promoted into the kit). Variants: default / primary / danger. It is a real
// Button, so Space/Enter activate it and Tab focuses it; activeFocus draws a
// keyboard focus ring. Optionally carries a leading Material Symbols icon.
import QtQuick
import QtQuick.Controls.Basic
import ".."

Button {
    id: btn
    property bool primary: false
    property bool danger: false
    property string glyph: ""
    implicitHeight: 36
    padding: 0
    opacity: enabled ? 1.0 : 0.4
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true

    background: Rectangle {
        radius: 10
        color: btn.danger  ? (btn.hovered || btn.down ? Qt.lighter(Colors.error, 1.12)   : Colors.error)
             : btn.primary ? (btn.hovered || btn.down ? Qt.lighter(Colors.primary, 1.12) : Colors.primary)
             :               (btn.hovered || btn.down ? Colors.surfaceHigh                : Colors.surface)
        border.color: btn.activeFocus ? Colors.primary
                    : ((btn.primary || btn.danger) ? "transparent" : Colors.outline)
        border.width: btn.activeFocus ? 2 : 1
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    contentItem: Row {
        spacing: 6
        leftPadding: 14
        rightPadding: 14
        Text {
            visible: btn.glyph.length > 0
            text: btn.glyph
            font.family: "Material Symbols Rounded"
            font.pixelSize: 16
            anchors.verticalCenter: parent.verticalCenter
            color: (btn.primary || btn.danger) ? Colors.onPrimary : Colors.onSurface
        }
        Text {
            text: btn.text
            anchors.verticalCenter: parent.verticalCenter
            color: (btn.primary || btn.danger) ? Colors.onPrimary : Colors.onSurface
            font.pixelSize: 13
            font.bold: btn.primary || btn.danger
        }
    }
}
