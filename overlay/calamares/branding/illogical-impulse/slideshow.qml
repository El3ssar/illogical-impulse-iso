/*
 * slideshow.qml
 *
 * Rework philosophy:
 *   - Preserve your minimalist screenshot-first layout.
 *   - Add interaction without turning it into visual sludge.
 *   - No giant overlays.
 *   - No excessive animation.
 *   - No fake gamer UI.
 */

import QtQuick 2.15

Item {
    id: root

    width:  parent ? parent.width : 900
    height: parent ? parent.height : 520
    focus: true

    readonly property color base:      "#1e1e2e"
    readonly property color mantle:    "#181825"
    readonly property color surface0:  "#313244"
    readonly property color text:      "#cdd6f4"
    readonly property color subtext:   "#bac2de"
    readonly property color accent:    "#cba6f7"

    property int currentIndex: 0
    property bool controlsVisible: false

    property var slides: [
        {
            image: "slides/01-desktop.png",
            title: "Welcome to Illogical Impulse",
            caption: "A Wayland-first Arch setup built around Hyprland and Quickshell."
        },
        {
            image: "slides/02-overview.png",
            title: "A desktop designed for movement",
            caption: "Workspace overview and fluid keyboard-centric navigation."
        },
        {
            image: "slides/03-launcher.png",
            title: "Wallpaper reactive theming",
            caption: "Matugen dynamically recolors the environment around your wallpaper."
        },
        {
            image: "slides/04-sidebar.png",
            title: "Useful information. Not clutter.",
            caption: "Notifications, media, AI tools and system metrics in one shell."
        },
        {
            image: "slides/05-music.png",
            title: "Designed for immersion",
            caption: "Ambient styling and integrated media controls."
        },
        {
            image: "slides/06-workspace.png",
            title: "Ready out of the box",
            caption: "Boot directly into a fully configured Hyprland environment."
        }
    ]

    readonly property var current: slides[currentIndex]

    function nextSlide() {
        currentIndex = (currentIndex + 1) % slides.length
        restartProgress()
    }

    function previousSlide() {
        currentIndex =
            (currentIndex - 1 + slides.length)
            % slides.length

        restartProgress()
    }

    function restartProgress() {
        progress.width = 0
        progressAnim.restart()
        slideTimer.restart()
    }

    Rectangle {
        anchors.fill: parent
        color: root.base
    }

    // ─────────────────────────────────────────────
    // Hero image
    // ─────────────────────────────────────────────

    Item {
        id: heroFrame

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right

        height: parent.height * 0.78
        clip: true

        Image {
            id: hero

            anchors.fill: parent

            source: current.image
            fillMode: Image.PreserveAspectFit

            asynchronous: true
            cache: true
            smooth: true

            opacity: 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                }
            }

            onStatusChanged: {
                if (status === Image.Ready)
                    opacity = 1
            }
        }

        // ─────────────────────────────────────────
        // Left button
        // ─────────────────────────────────────────

        Rectangle {
            id: leftButton

            width: 42
            height: 42
            radius: 21

            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter

            color: "#66181825"
            border.width: 1
            border.color: "#33ffffff"

            opacity: leftMouse.containsMouse
                ? 1.0
                : 0.0

            visible: root.controlsVisible

            Behavior on opacity {
                NumberAnimation {
                    duration: 140
                }
            }

            Text {
                anchors.centerIn: parent
                text: "‹"

                color: root.text

                font.pixelSize: 28
                font.family: "Inter"
            }

            MouseArea {
                id: leftMouse

                anchors.fill: parent
                hoverEnabled: true

                onClicked: root.previousSlide()
            }
        }

        // ─────────────────────────────────────────
        // Right button
        // ─────────────────────────────────────────

        Rectangle {
            id: rightButton

            width: 42
            height: 42
            radius: 21

            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter

            color: "#66181825"
            border.width: 1
            border.color: "#33ffffff"

            opacity: rightMouse.containsMouse
                ? 1.0
                : 0.0

            visible: root.controlsVisible

            Behavior on opacity {
                NumberAnimation {
                    duration: 140
                }
            }

            Text {
                anchors.centerIn: parent
                text: "›"

                color: root.text

                font.pixelSize: 28
                font.family: "Inter"
            }

            MouseArea {
                id: rightMouse

                anchors.fill: parent
                hoverEnabled: true

                onClicked: root.nextSlide()
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true

            onEntered: root.controlsVisible = true
            onExited: root.controlsVisible = false
        }
    }

    // ─────────────────────────────────────────────
    // Bottom panel
    // ─────────────────────────────────────────────

    Rectangle {
        id: bottomPanel

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        height: parent.height * 0.22

        color: root.mantle

        border.width: 1
        border.color: root.surface0
    }

    // ─────────────────────────────────────────────
    // Progress track
    // ─────────────────────────────────────────────

    Rectangle {
        anchors.top: bottomPanel.top
        anchors.left: bottomPanel.left
        anchors.right: bottomPanel.right

        height: 2
        color: "#22313244"
    }

    Rectangle {
        id: progress

        anchors.left: parent.left
        anchors.bottom: bottomPanel.top

        width: 0
        height: 2

        color: root.accent
    }

    PropertyAnimation {
        id: progressAnim

        target: progress
        property: "width"

        from: 0
        to: root.width

        duration: 8000

        easing.type: Easing.Linear
    }

    Timer {
        id: slideTimer

        interval: 8000
        repeat: true
        running: true

        onTriggered: {
            root.currentIndex =
                (root.currentIndex + 1)
                % root.slides.length

            progress.width = 0
            progressAnim.restart()
        }
    }

    Component.onCompleted: {
        progressAnim.start()
    }

    // ─────────────────────────────────────────────
    // Text content
    // ─────────────────────────────────────────────

    Column {
        anchors.left: parent.left
        anchors.bottom: parent.bottom

        anchors.leftMargin: 36
        anchors.bottomMargin: 28

        spacing: 10

        Text {
            text: current.title
            color: root.accent

            font.family: "Inter"
            font.pixelSize: 26
            font.weight: Font.DemiBold
        }

        Text {
            text: current.caption

            width: root.width * 0.62
            wrapMode: Text.WordWrap

            color: root.subtext

            font.family: "Inter"
            font.pixelSize: 14
            font.weight: Font.Medium

            lineHeight: 1.25
        }
    }

    // ─────────────────────────────────────────────
    // Pagination dots
    // ─────────────────────────────────────────────

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom

        anchors.bottomMargin: 22

        spacing: 10

        Repeater {
            model: slides.length

            Rectangle {
                width: index === root.currentIndex ? 22 : 8
                height: 8

                radius: 999

                color: index === root.currentIndex
                    ? root.accent
                    : "#556c7086"

                Behavior on width {
                    NumberAnimation {
                        duration: 160
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 160
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // Keyboard navigation
    // ─────────────────────────────────────────────

    Keys.onLeftPressed: {
        root.previousSlide()
    }

    Keys.onRightPressed: {
        root.nextSlide()
    }
}
