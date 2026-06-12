//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Illogical Impulse — distro welcome card.
//
// Deliberately standalone: its own Quickshell config dir, plain QtQuick,
// ZERO imports from upstream's shell tree — if end-4 redesigns the rice
// tomorrow, this still runs. Shown once on the login after upstream's own
// welcome app (sequencing lives in `iictl welcome --auto`); reopen anytime
// with `iictl welcome`.

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ApplicationWindow {
    id: root
    visible: true
    title: "Illogical Impulse"
    width: 480
    height: 540
    minimumWidth: 440
    minimumHeight: 500
    color: "#1E202B"

    readonly property string teal: "#45DDBC"
    readonly property string text0: "#CDD6F4"
    readonly property string text1: "#8E95B3"
    readonly property string isoVersion: Quickshell.env("ISO_RELEASE_VERSION") || "unknown"
    readonly property string dotsCommit: Quickshell.env("ISO_RELEASE_DOTS") || ""

    function runInTerminal(cmd, title) {
        Quickshell.execDetached(["kitty", "--title", title, "-e", "bash", "-lc",
            cmd + '; echo; read -rp "Press Enter to close..."'])
    }

    component ActionButton: Button {
        id: btn
        property bool primary: false
        Layout.fillWidth: true
        implicitHeight: 44
        background: Rectangle {
            radius: 12
            color: btn.primary
                ? (btn.hovered ? "#5FE8CB" : root.teal)
                : (btn.hovered ? "#323848" : "#282E3D")
            border.color: btn.primary ? "transparent" : "#3A4154"
            border.width: 1
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        contentItem: Text {
            text: btn.text
            color: btn.primary ? "#16281F" : root.text0
            font.pixelSize: 14
            font.bold: btn.primary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 0

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 120
            Layout.preferredHeight: 120
            Rectangle {   // soft teal halo behind the icon
                anchors.centerIn: parent
                width: 118; height: 118; radius: 59
                color: "transparent"
                border.color: Qt.alpha(root.teal, 0.35)
                border.width: 2
            }
            Image {
                anchors.centerIn: parent
                source: "/usr/share/pixmaps/illogical-impulse.png"
                sourceSize.width: 104
                sourceSize.height: 104
            }
        }

        Text {
            textFormat: Text.RichText
            text: 'Welcome to <font color="' + root.teal + '">Illogical Impulse</font>'
            color: root.text0
            font.pixelSize: 22
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 18
        }

        Rectangle {   // thin brand rule under the title
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 10
            width: 190; height: 2; radius: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: root.teal }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        Text {
            text: "release " + root.isoVersion
                  + (root.dotsCommit ? "  ·  dots @ " + root.dotsCommit : "")
            color: root.text1
            font.pixelSize: 13
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
        }

        Text {
            text: "Your system is fully set up — rice, apps, drivers.\nA couple of useful things before you fly:"
            color: root.text1
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 14
        }

        ColumnLayout {
            spacing: 10
            Layout.fillWidth: true
            Layout.topMargin: 20

            ActionButton {
                primary: true
                text: "Update everything  (repos + AUR + dots)"
                onClicked: root.runInTerminal("iictl update --system", "Illogical Impulse — update")
            }
            ActionButton {
                text: "Run a health check"
                onClicked: root.runInTerminal("iictl doctor", "Illogical Impulse — doctor")
            }
        }

        Item { Layout.fillHeight: true }

        Text {
            textFormat: Text.RichText
            text: "<b>Super + /</b> keybinds  ·  <b>Super + I</b> rice settings"
                  + "<br>All of this lives in <tt>iictl</tt> — try <tt>iictl doctor</tt> in a terminal."
                  + "<br>Reopen this card with <tt>iictl welcome</tt> or from the app launcher."
            color: root.text1
            font.pixelSize: 12
            lineHeight: 1.4
            horizontalAlignment: Text.AlignHCenter
            Layout.alignment: Qt.AlignHCenter
        }

        ActionButton {
            text: "Let's go"
            Layout.topMargin: 16
            Layout.preferredWidth: 160
            Layout.fillWidth: false
            Layout.alignment: Qt.AlignHCenter
            onClicked: Qt.quit()
        }
    }
}
