// Theme & Wallpaper pane — the Material You flavor engine (`iictl theme`, #16/#26)
// rendered via the generic chooser, plus wallpaper quick actions. Wallpaper fetch
// and the interactive chooser open in a terminal (they download / need a picker);
// the theme controls (flavor, feeder, plymouth…) are native GUI via SpecForm.
import QtQuick
import QtQuick.Layouts
import ".."
import "../_ui"

Item {
    id: pane

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        // wallpaper quick bar
        Card {
            Layout.fillWidth: true
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text { text: "Wallpaper"; color: Colors.onSurface; font.pixelSize: 15; font.bold: true }
                    Text {
                        text: "Change the wallpaper (colours regenerate live) or fetch the curated pack."
                        color: Colors.onSurfaceVariant
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
                PillButton {
                    glyph: "wallpaper"
                    text: "Change…"
                    onClicked: Ctl.runInTerminal("iictl tweak wallpaper", "Wallpaper")
                }
                PillButton {
                    glyph: "download"
                    text: "Fetch pack"
                    onClicked: Ctl.runInTerminal("iictl wallpaper pack", "Fetch wallpapers")
                }
            }
        }

        // theme flavor engine (native GUI chooser)
        SpecForm {
            Layout.fillWidth: true
            Layout.fillHeight: true
            domain: "theme"
            heading: "Theme"
            blurb: "Material You flavor and coherence over upstream's colour engine. Everything is reversible; the app re-themes live as the palette changes."
        }
    }
}
