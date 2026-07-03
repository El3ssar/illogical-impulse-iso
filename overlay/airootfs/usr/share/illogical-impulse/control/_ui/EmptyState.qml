// EmptyState — the honest "nothing here" rendering every data view uses instead
// of a blank pane: a soft icon, a message, and an optional action slot.
import QtQuick
import QtQuick.Layouts
import ".."

ColumnLayout {
    id: es
    property string glyph: "inbox"
    property string message: "Nothing to show."
    default property alias action: act.data
    spacing: 12

    Text {
        Layout.alignment: Qt.AlignHCenter
        text: es.glyph
        font.family: "Material Symbols Rounded"
        font.pixelSize: 44
        color: Qt.alpha(Colors.onSurfaceVariant, 0.6)
    }
    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: 360
        text: es.message
        color: Colors.onSurfaceVariant
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
    RowLayout {
        id: act
        Layout.alignment: Qt.AlignHCenter
        spacing: 8
    }
}
