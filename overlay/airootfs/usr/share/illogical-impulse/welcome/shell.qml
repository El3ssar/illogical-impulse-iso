//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Illogical Impulse — distro welcome card.
//
// Deliberately standalone: its own Quickshell config dir, plain QtQuick,
// ZERO imports from upstream's shell tree — if end-4 redesigns the rice
// tomorrow, this still runs. Shown once on the INSTALLED user's first login IN
// PLACE OF upstream's own welcome (suppressed by the pre-seeded first_run.txt
// marker in skel-distro → /etc/skel; sequencing in `iictl welcome --auto`). The
// liveuser keeps upstream's first-run (it has the installer launcher instead).
// Reopen anytime with `iictl welcome` (or bare `iictl`).
//
// Actions run in an EMBEDDED console — a Quickshell.Io.Process streamed into
// the window — so NO external terminal window pops up. A system update needs
// root, so an in-window password field primes sudo via `sudo -S`: the password
// is written to the child's stdin only, never placed in argv or the environment.

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ApplicationWindow {
    id: root
    visible: true
    title: "Illogical Impulse"
    width: 520
    height: 600
    minimumWidth: 460
    minimumHeight: 540
    color: "#1E202B"

    readonly property string teal: "#45DDBC"
    readonly property string text0: "#CDD6F4"
    readonly property string text1: "#8E95B3"
    readonly property string red: "#F38BA8"
    readonly property string mono: "#11131A"
    readonly property string isoVersion: Quickshell.env("ISO_RELEASE_VERSION") || "unknown"
    readonly property string dotsCommit: Quickshell.env("ISO_RELEASE_DOTS") || ""

    // ── view + run state ─────────────────────────────────────────────────
    property string view: "home"          // "home" | "console"
    property string runTitle: ""
    property string runCmd: ""
    property bool   needsAuth: false
    property bool   awaitingPw: false      // showing the password prompt, pre-run
    property bool   busy: false            // a command is currently running
    property bool   finished: false
    property int    exitCode: -1
    property string pendingPw: ""          // held only between submit and the stdin write

    function startRun(title, cmd) {        // no privilege needed → run immediately
        root.runTitle = title; root.runCmd = cmd;
        root.needsAuth = false; root.awaitingPw = false;
        root.view = "console";
        beginRun();
    }
    function startAuth(title, cmd) {       // needs root → ask for the password first
        root.runTitle = title; root.runCmd = cmd;
        root.needsAuth = true; root.awaitingPw = true;
        root.view = "console";
        pwField.text = ""; pwField.forceActiveFocus();
    }
    function submitPw() {
        if (pwField.text.length === 0) return;
        root.pendingPw = pwField.text; pwField.text = "";
        root.awaitingPw = false;
        beginRun();
    }
    // Build the bash payload. NO_COLOR/TERM keep tool output free of ANSI escapes
    // (output goes to a pipe, so most tools already drop colour — belt + braces).
    // A trailing __IICTL_RC sentinel reports the real exit code through the stream,
    // so completion detection never depends on a parser/signal race.
    function buildPayload(cmd, auth) {
        var pre = "export NO_COLOR=1 TERM=dumb; ";
        var tail = " 2>&1; printf '\\n__IICTL_RC:%d\\n' \"$?\"";
        if (auth)
            return pre + "sudo -S -p '' -v 2>/dev/null || "
                 + "{ echo; echo 'Authentication failed — wrong password?'; printf '__IICTL_RC:1\\n'; exit 1; }; "
                 + cmd + tail;
        return pre + cmd + tail;
    }
    function beginRun() {
        outArea.text = "";
        root.finished = false; root.exitCode = -1; root.busy = true;
        proc.command = ["bash", "-c", buildPayload(root.runCmd, root.needsAuth)];
        proc.running = true;
    }
    function appendChunk(line) {
        if (line.indexOf("__IICTL_RC:") === 0) {
            root.exitCode = parseInt(line.substring("__IICTL_RC:".length)) || 0;
            return;                        // sentinel — never shown
        }
        outArea.text += line + "\n";
        flick.contentY = Math.max(0, outArea.implicitHeight - flick.height);   // autoscroll
    }
    function goHome() {
        if (root.busy) return;
        root.view = "home"; root.awaitingPw = false;
        root.runTitle = ""; root.runCmd = ""; outArea.text = "";
        root.finished = false; root.exitCode = -1;
    }

    onClosing: (close) => { if (root.busy) close.accepted = false; }   // never abort a running update

    Process {
        id: proc
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.appendChunk(data) }
        stderr: SplitParser { onRead: data => root.appendChunk(data) }
        onRunningChanged: {
            if (proc.running) {
                if (root.needsAuth && root.pendingPw.length > 0) {
                    proc.write(root.pendingPw + "\n");
                    root.pendingPw = "";
                }
            } else {
                root.busy = false;
                root.finished = true;
            }
        }
    }

    // ── shared pill button ───────────────────────────────────────────────
    component ActionButton: Button {
        id: btn
        property bool primary: false
        implicitHeight: 42
        opacity: enabled ? 1.0 : 0.45
        background: Rectangle {
            radius: 12
            color: btn.primary ? (btn.hovered ? "#5FE8CB" : root.teal)
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

    // =====================================================================
    // HOME VIEW
    // =====================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 0
        visible: root.view === "home"

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
                Layout.fillWidth: true
                text: "Update everything  (repos + AUR + dots)"
                onClicked: root.startAuth("Update everything", "iictl update --system")
            }
            ActionButton {
                Layout.fillWidth: true
                text: "Run a health check"
                onClicked: root.startRun("Health check", "iictl doctor")
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

    // =====================================================================
    // CONSOLE VIEW
    // =====================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 12
        visible: root.view === "console"

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: root.runTitle
                color: root.text0
                font.pixelSize: 18
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            BusyIndicator {
                running: root.busy
                visible: root.busy
                implicitWidth: 22; implicitHeight: 22
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: "#2A3040" }

        // ── password prompt (privileged actions only, before the run) ──────
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.awaitingPw
            spacing: 10

            Text {
                text: "Updating system packages needs administrator rights.\nEnter your password to continue:"
                color: root.text1
                font.pixelSize: 13
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
            TextField {
                id: pwField
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: "Password"
                color: root.text0
                placeholderTextColor: root.text1
                background: Rectangle {
                    radius: 8
                    color: "#23283A"
                    border.color: root.teal
                    border.width: 1
                }
                onAccepted: root.submitPw()
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ActionButton {
                    primary: true
                    Layout.fillWidth: true
                    text: "Run update"
                    enabled: pwField.text.length > 0
                    onClicked: root.submitPw()
                }
                ActionButton {
                    Layout.preferredWidth: 120
                    text: "Cancel"
                    onClicked: root.goHome()
                }
            }
        }

        // ── streaming output console ───────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.awaitingPw
            radius: 10
            color: root.mono
            border.color: "#2A3040"
            border.width: 1

            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentWidth: outArea.implicitWidth
                contentHeight: outArea.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                TextEdit {
                    id: outArea
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.NoWrap
                    textFormat: TextEdit.PlainText
                    color: root.text0
                    font.family: "monospace"
                    font.pixelSize: 12
                    text: ""
                }
            }

            Text {   // placeholder before any output arrives
                anchors.centerIn: parent
                visible: outArea.text.length === 0 && root.busy
                text: "Starting…"
                color: root.text1
                font.pixelSize: 13
            }
        }

        // ── status + actions (hidden while choosing the password) ──────────
        RowLayout {
            Layout.fillWidth: true
            visible: !root.awaitingPw
            spacing: 10

            Text {
                Layout.fillWidth: true
                color: root.busy ? root.text1 : (root.exitCode === 0 ? root.teal : root.red)
                font.pixelSize: 13
                text: root.busy ? "Working…"
                    : root.finished ? (root.exitCode === 0 ? "Done." : "Failed (exit " + root.exitCode + ").")
                    : ""
            }
            ActionButton {
                Layout.preferredWidth: 110
                text: "Back"
                enabled: !root.busy
                onClicked: root.goHome()
            }
            ActionButton {
                Layout.preferredWidth: 110
                text: "Close"
                enabled: !root.busy
                onClicked: Qt.quit()
            }
        }
    }
}
