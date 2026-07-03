// Perks pane — the hub for the remaining reversible domains that don't warrant a
// dedicated rail entry: the terminal/multiplexer chooser (#23), desktop widgets
// (#20), web apps (#21), config export/import (#27), and one-time migrations.
// In-window actions stream through the Console; interactive TUIs (the ratatui
// tweak chooser) open in a terminal. Every domain here is fully reversible.
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../_ui"

Item {
    id: pane
    function runAction(cmd, title) { consoleOverlay.run(cmd, title); }

    Flickable {
        anchors.fill: parent
        visible: !consoleOverlay.open
        clip: true
        contentWidth: width
        contentHeight: col.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: col
            width: parent.width
            spacing: 14

            // Terminal & multiplexer (#23)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Terminal & multiplexer"
                    subtitle: "Pick the terminal emulator + multiplexer (kitty/ghostty/wezterm/alacritty/foot · zellij/tmux). Graceful fallback, reversible."
                    RowLayout {
                        spacing: 10
                        PillButton { glyph: "dvr"; text: "Configure…"; onClicked: Ctl.runInTerminal("iictl tweak tui", "Terminal & multiplexer") }
                        PillButton { glyph: "info"; text: "Status"; onClicked: pane.runAction("iictl tui status", "Terminal status") }
                    }
                }
            }

            // Desktop widgets (#20)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Desktop widgets"
                    subtitle: "Enable Quickshell desktop widgets (dev dashboard…). Reach them with the SUPER+ALT+W leader; toggling is ledger-recorded and reversible."
                    RowLayout {
                        spacing: 10
                        PillButton { glyph: "widgets"; text: "Configure…"; onClicked: Ctl.runInTerminal("iictl tweak widget", "Widgets") }
                        PillButton { glyph: "list"; text: "List"; onClicked: pane.runAction("iictl widget list", "Widgets") }
                    }
                }
            }

            // Web apps (#21)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Web apps"
                    subtitle: "Brave --app launchers for your favourite sites, accent-aware and reversible. Seed the curated defaults or manage your own."
                    RowLayout {
                        spacing: 10
                        PillButton { glyph: "add_to_home_screen"; text: "Seed defaults"; onClicked: pane.runAction("iictl webapp seed", "Seed web apps") }
                        PillButton { glyph: "apps"; text: "Manage…"; onClicked: Ctl.runInTerminal("iictl webapp", "Web apps") }
                    }
                }
            }

            // Config export/import (#27)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Portable setup"
                    subtitle: "Export the whole reversible setup (ledger + choices) to a bundle, or import one on another machine."
                    RowLayout {
                        spacing: 10
                        PillButton { glyph: "ios_share"; text: "Export…"; onClicked: Ctl.runInTerminal("iictl config export", "Export setup") }
                        PillButton { glyph: "download"; text: "Import…"; onClicked: Ctl.runInTerminal("iictl config import", "Import setup") }
                    }
                }
            }

            // Migrations
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Migrations"
                    subtitle: "One-time schema/setting migrations shipped with updates. Preview what's pending, then apply."
                    RowLayout {
                        spacing: 10
                        PillButton { glyph: "playlist_add_check"; text: "Pending"; onClicked: pane.runAction("iictl migrate --list", "Pending migrations") }
                        PillButton { glyph: "play_arrow"; text: "Apply"; onClicked: pane.runAction("iictl migrate", "Apply migrations") }
                    }
                }
            }

            // All tweak domains
            Card {
                Layout.fillWidth: true
                Section {
                    title: "All tweaks"
                    subtitle: "Open the full interactive chooser for every configurable domain."
                    PillButton { glyph: "tune"; text: "Open tweak menu"; onClicked: Ctl.runInTerminal("iictl tweak", "iictl tweak") }
                }
            }
        }
    }

    Console {
        id: consoleOverlay
        anchors.fill: parent
        onDone: function (code) {
            toast.show(code === 0 ? "Done." : "Failed (exit " + code + ").", code !== 0);
        }
    }
    Toast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
    }
}
