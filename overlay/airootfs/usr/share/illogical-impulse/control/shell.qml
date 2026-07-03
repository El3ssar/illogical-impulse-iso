//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Illogical Impulse — the distro Control Center (issue #14, the CENTERPIECE).
//
// A standalone Quickshell app that is the graphical home for every reversible
// `iictl` tweak. Built on the exact welcome-card pattern: UseQApplication, plain
// QtQuick + Controls.Basic, and ZERO imports from upstream's quickshell/ii tree —
// so if end-4 redesigns the rice tomorrow, this still runs, and deleting the
// control/ dir + its launch surfaces leaves the rice byte-for-byte unchanged
// (Iron Law: additive & reversible). It is DISTINCT from upstream's Super+I rice
// Settings — it complements, never replaces it.
//
// The rail + the pane StackLayout are GENERATED from control/panes.js (the pane
// registry) — adding a feature is a drop-in (panes/<X>.qml + one registry line),
// the GUI analogue of iictl.d/<verb>. Every pane composes control/_ui/ (the shared
// design system) and drives the system ONLY through the Ctl singleton → `iictl`
// (no pane mutates the filesystem; each iictl verb records its own ledger entry).
//
// Launched four ways: the .desktop entry, SUPER+SHIFT+I, the welcome-card button,
// and `iictl center`.

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "_ui"
import "panes.js" as Registry

ApplicationWindow {
    id: root
    visible: true
    // Identity is NOT hardcoded: the distro NAME comes from the build-generated
    // os-release (derived from distro.toml), passed by `iictl center` via the env.
    // A direct `qs -p` (dev/test) with no env falls back to the brand-neutral name.
    readonly property string distroName: Quickshell.env("II_DISTRO_NAME") || ""
    title: "Control Center" + (root.distroName.length ? " — " + root.distroName : "")
    width: 960
    height: 640
    minimumWidth: 760
    minimumHeight: 520
    color: Colors.background

    readonly property var panes: Registry.PANES
    property int currentIndex: 0
    readonly property var current: panes[currentIndex]

    // ── global cross-pane search ──────────────────────────────────────────────
    property string query: ""
    property int searchSel: 0
    readonly property var results: _search(query)
    readonly property bool searchOpen: query.trim().length > 0 && search.input.activeFocus

    function _search(q) {
        q = String(q).trim().toLowerCase();
        if (!q.length) return [];
        var out = [];
        for (var i = 0; i < panes.length; ++i) {
            var p = panes[i];
            var hay = (p.title + " " + (p.verb || "") + " " + ((p.keywords || []).join(" "))).toLowerCase();
            if (hay.indexOf(q) >= 0) out.push({ index: i, pane: p });
        }
        return out;
    }
    function go(i) {
        if (i < 0 || i >= panes.length) return;
        root.currentIndex = i;
        fadeAnim.restart();
    }
    function jumpToResult() {
        if (results.length === 0) return;
        var sel = Math.max(0, Math.min(searchSel, results.length - 1));
        go(results[sel].index);
        closeSearch();
    }
    function closeSearch() {
        search.text = ""; root.query = ""; root.searchSel = 0;
        railFocus.forceActiveFocus();
    }
    // Duck-type: is a text input focused? (so "/" and Esc don't hijack typing)
    function _typing() {
        var f = root.activeFocusItem;
        return !!(f && typeof f.selectedText !== "undefined");
    }

    // ── keyboard ──────────────────────────────────────────────────────────────
    Shortcut { sequences: ["Ctrl+F"]; onActivated: search.focusInput() }
    Shortcut { sequence: "/"; enabled: !root._typing(); onActivated: search.focusInput() }
    Shortcut { sequences: ["Ctrl+Q"]; onActivated: Qt.quit() }
    Shortcut { sequence: "Esc"; enabled: !root.searchOpen && !root._typing(); onActivated: Qt.quit() }
    // Alt+1..9 jump straight to a pane.
    Instantiator {
        model: Math.min(9, root.panes.length)
        delegate: Shortcut {
            required property int index
            sequence: "Alt+" + (index + 1)
            onActivated: root.go(index)
        }
    }

    // =========================================================================
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ── NAVIGATION RAIL ──────────────────────────────────────────────────
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 96
            color: Colors.surfaceLow

            ColumnLayout {
                id: railFocus
                anchors.fill: parent
                anchors.topMargin: 16
                anchors.bottomMargin: 14
                spacing: 4

                // brand header
                ColumnLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.bottomMargin: 10
                    spacing: 4
                    Image {
                        Layout.alignment: Qt.AlignHCenter
                        source: "/usr/share/pixmaps/illogical-impulse.png"
                        sourceSize.width: 34
                        sourceSize.height: 34
                        fillMode: Image.PreserveAspectFit
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Control"
                        color: Colors.onSurfaceVariant
                        font.pixelSize: 10
                        font.bold: true
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: railCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ColumnLayout {
                        id: railCol
                        width: parent.width
                        spacing: 2
                        Repeater {
                            model: root.panes
                            delegate: NavRailButton {
                                required property var modelData
                                required property int index
                                Layout.alignment: Qt.AlignHCenter
                                text: modelData.title
                                glyph: modelData.glyph
                                selected: root.currentIndex === index
                                onClicked: root.go(index)
                            }
                        }
                    }
                }

                // footer: restore-vanilla shortcut hint
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: 84
                    text: "Alt+1–9 · /"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: Qt.alpha(Colors.onSurfaceVariant, 0.7)
                    font.pixelSize: 9
                }
            }
        }

        Rectangle { Layout.fillHeight: true; Layout.preferredWidth: 1; color: Colors.outline; opacity: 0.6 }

        // ── MAIN COLUMN ──────────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // top bar: current title + global search
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 18
                Layout.bottomMargin: 8
                spacing: 14
                Text {
                    text: root.current ? root.current.title : ""
                    color: Colors.onSurface
                    font.pixelSize: 20
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                SearchField {
                    id: search
                    Layout.preferredWidth: 300
                    placeholder: "Search settings…  ( / )"
                    onTextEdited: function (t) { root.query = t; root.searchSel = 0; }
                    onAccepted: root.jumpToResult()
                    onEscaped: root.closeSearch()
                    onUp: root.searchSel = Math.max(0, root.searchSel - 1)
                    onDown: root.searchSel = root.results.length === 0 ? 0
                          : Math.min(root.results.length - 1, root.searchSel + 1)
                }
            }

            // pane stack
            StackLayout {
                id: stack
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 18
                Layout.rightMargin: 18
                Layout.bottomMargin: 18
                currentIndex: root.currentIndex

                Repeater {
                    model: root.panes
                    delegate: Loader {
                        required property var modelData
                        required property int index
                        // lazy: load a pane on first visit, keep it loaded after.
                        active: root.currentIndex === index || status === Loader.Ready
                        source: Qt.resolvedUrl(modelData.source)
                        opacity: status === Loader.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 150 } }
                        // Honest error if a pane file is missing/broken.
                        onStatusChanged: if (status === Loader.Error)
                            console.warn("Control Center: failed to load pane", modelData.source);
                    }
                }
            }
        }
    }

    // subtle cross-pane fade on switch
    NumberAnimation { id: fadeAnim; target: stack; property: "opacity"; from: 0.55; to: 1; duration: 160 }

    // ── global search results overlay ─────────────────────────────────────────
    Rectangle {
        id: searchOverlay
        visible: root.searchOpen
        z: 100
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 18
        anchors.topMargin: 66
        width: 320
        implicitHeight: Math.min(resultsCol.implicitHeight + 12, 380)
        radius: 12
        color: Colors.surface
        border.color: Colors.outline
        border.width: 1

        Column {
            id: resultsCol
            anchors.fill: parent
            anchors.margins: 6
            spacing: 2

            Text {
                visible: root.results.length === 0
                width: parent.width
                padding: 12
                text: "No settings match “" + root.query.trim() + "”."
                color: Colors.onSurfaceVariant
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            Repeater {
                model: root.results
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: resultsCol.width
                    height: 42
                    radius: 8
                    color: index === root.searchSel ? Qt.alpha(Colors.primary, 0.16)
                         : (rHover.hovered ? Colors.surfaceHigh : "transparent")
                    HoverHandler { id: rHover }
                    TapHandler { onTapped: { root.searchSel = index; root.jumpToResult(); } }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10
                        Text {
                            text: modelData.pane.glyph
                            font.family: "Material Symbols Rounded"
                            font.pixelSize: 18
                            color: index === root.searchSel ? Colors.primary : Colors.onSurfaceVariant
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.pane.title
                            color: Colors.onSurface
                            font.pixelSize: 13
                            font.bold: index === root.searchSel
                            elide: Text.ElideRight
                        }
                        Text {
                            text: "↵"
                            visible: index === root.searchSel
                            color: Colors.onSurfaceVariant
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }
}
