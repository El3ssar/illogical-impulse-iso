// Icon — a Material Symbols glyph rendered by ligature name (e.g. name:"dashboard").
// Material Symbols Rounded is the rice's own icon font (ships with the upstream
// dots), so glyphs match the desktop and are guaranteed present in the session.
// Reads Colors so icons re-theme with the wallpaper.
import QtQuick
import ".."

Text {
    id: ico
    property string name: ""
    property bool fill: false
    text: name
    color: Colors.onSurface
    font.family: "Material Symbols Rounded"
    font.pixelSize: 20
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
