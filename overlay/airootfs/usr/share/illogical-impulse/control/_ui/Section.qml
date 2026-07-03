// Section — a titled group of controls with an optional subtitle. Panes stack
// Sections to organize their content; the header re-themes from Colors.
import QtQuick
import QtQuick.Layouts
import ".."

ColumnLayout {
    id: sec
    property string title: ""
    property string subtitle: ""
    default property alias content: body.data
    spacing: 10
    Layout.fillWidth: true

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        visible: sec.title.length > 0 || sec.subtitle.length > 0
        Text {
            text: sec.title
            color: Colors.onSurface
            font.pixelSize: 15
            font.bold: true
            visible: sec.title.length > 0
        }
        Text {
            text: sec.subtitle
            color: Colors.onSurfaceVariant
            font.pixelSize: 12
            visible: sec.subtitle.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }
    }

    ColumnLayout {
        id: body
        Layout.fillWidth: true
        spacing: 8
    }
}
