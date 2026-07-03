// ListRow — a title/subtitle row with a trailing slot for actions (buttons,
// badges). Hoverable and (optionally) clickable. Used by list/search views.
import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: row
    property string title: ""
    property string subtitle: ""
    property bool active: false
    property bool interactive: true
    default property alias trailing: trail.data
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: Math.max(48, content.implicitHeight + 16)
    radius: 9
    color: row.active ? Qt.alpha(Colors.primary, 0.12)
         : (hover.hovered ? Colors.surfaceHigh : "transparent")
    Behavior on color { ColorAnimation { duration: 90 } }

    HoverHandler { id: hover; enabled: row.interactive }
    TapHandler { enabled: row.interactive; onTapped: row.clicked() }

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 10

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
                text: row.title
                color: Colors.onSurface
                font.pixelSize: 14
                font.bold: true
                visible: text.length > 0
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Text {
                text: row.subtitle
                color: Colors.onSurfaceVariant
                font.pixelSize: 12
                visible: text.length > 0
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        RowLayout { id: trail; spacing: 6 }
    }
}
