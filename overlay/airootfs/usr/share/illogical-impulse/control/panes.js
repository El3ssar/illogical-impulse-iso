.pragma library

// The Control Center pane registry (issue #14). The left NavigationRail and the
// StackLayout of panes are GENERATED from this array — no pane is hand-wired into
// shell.qml. Adding a feature is a drop-in: create panes/<X>.qml and add ONE line
// here (the GUI analogue of the iictl.d/<verb> drop-in model). This keeps the
// shell closed for modification and open for extension.
//
// Descriptor fields:
//   id        stable key
//   title     rail label + window/section heading
//   glyph     Material Symbols Rounded ligature name (the rice's icon font)
//   source    pane QML file (an Item root, embedded via Loader)
//   verb      the primary `iictl` verb the pane drives (documentation/search)
//   keywords  extra terms the global cross-pane search matches on
//
// A pane whose domain verb is not yet present should point `source` at
// panes/Placeholder.qml (it renders the verb's --spec/--json when it lands).
var PANES = [
    { id: "overview", title: "Overview",           glyph: "dashboard",     source: "panes/Overview.qml",
      keywords: ["home", "status", "doctor", "version", "update", "revert", "welcome"] },
    { id: "packages", title: "Packages",           glyph: "deployed_code", source: "panes/Packages.qml", verb: "pkg",
      keywords: ["software", "install", "remove", "aur", "search", "pacman", "paru", "orphans"] },
    { id: "shell",    title: "Shell",              glyph: "terminal",      source: "panes/Shell.qml",   verb: "shell",
      keywords: ["fish", "zsh", "bash", "fizsh", "nushell", "login shell", "prompt", "plugins"] },
    { id: "editor",   title: "Editor",             glyph: "edit_note",     source: "panes/Editor.qml",  verb: "nvim",
      keywords: ["neovim", "nvim", "lazyvim", "astronvim", "nvchad", "kickstart", "plain", "ide"] },
    { id: "plugins",  title: "Plugins",            glyph: "extension",     source: "panes/Plugins.qml", verb: "plugins",
      keywords: ["zsh", "antidote", "ohmyzsh", "git", "plugin", "bundle"] },
    { id: "devpacks", title: "Dev Packs",          glyph: "inventory_2",   source: "panes/DevPacks.qml", verb: "pack",
      keywords: ["gaming", "creative", "virt", "security", "containers", "language", "ai", "backup", "flatpak"] },
    { id: "theme",    title: "Theme & Wallpaper",  glyph: "palette",       source: "panes/Theme.qml",   verb: "theme",
      keywords: ["colors", "material you", "wallpaper", "flavor", "plymouth", "feeder", "gtk", "cursor"] },
    { id: "perks",    title: "Perks",              glyph: "auto_awesome",  source: "panes/Perks.qml",   verb: "tweak",
      keywords: ["terminal", "multiplexer", "zellij", "tmux", "webapp", "widget", "config", "migrate", "extras", "tweaks"] },
    { id: "updates",  title: "System & Updates",   glyph: "update",        source: "panes/System.qml",  verb: "update",
      keywords: ["update", "channel", "stable", "edge", "doctor", "venv", "driver", "nvidia", "restore", "revert"] }
];
