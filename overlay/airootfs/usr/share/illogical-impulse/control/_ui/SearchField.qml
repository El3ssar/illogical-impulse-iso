// SearchField — a themed search input with a leading Material Symbols glyph, a
// clear button, and a focus ring. Used for the global cross-pane search and for
// pane-local search. Exposes accepted()/escaped()/textEdited and focusInput().
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Rectangle {
    id: sf
    property alias text: field.text
    property string placeholder: "Search…"
    property alias input: field
    signal accepted()
    signal escaped()
    signal textEdited(string text)
    signal up()
    signal down()

    implicitHeight: 40
    radius: 10
    color: Colors.surface
    border.color: field.activeFocus ? Colors.primary : Colors.outline
    border.width: field.activeFocus ? 2 : 1
    Behavior on border.color { ColorAnimation { duration: 120 } }

    function focusInput() { field.forceActiveFocus() }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        spacing: 8

        Text {
            text: "search"
            font.family: "Material Symbols Rounded"
            font.pixelSize: 18
            color: Colors.onSurfaceVariant
        }

        TextField {
            id: field
            Layout.fillWidth: true
            placeholderText: sf.placeholder
            color: Colors.onSurface
            placeholderTextColor: Colors.onSurfaceVariant
            selectByMouse: true
            padding: 0
            background: null
            onTextEdited: sf.textEdited(field.text)
            Keys.onReturnPressed: sf.accepted()
            Keys.onEnterPressed: sf.accepted()
            Keys.onEscapePressed: sf.escaped()
            Keys.onUpPressed: sf.up()
            Keys.onDownPressed: sf.down()
        }

        Text {
            text: "close"
            font.family: "Material Symbols Rounded"
            font.pixelSize: 18
            color: clearHover.hovered ? Colors.onSurface : Colors.onSurfaceVariant
            visible: field.text.length > 0
            HoverHandler { id: clearHover }
            TapHandler { onTapped: { field.text = ""; sf.textEdited(""); field.forceActiveFocus() } }
        }
    }
}
