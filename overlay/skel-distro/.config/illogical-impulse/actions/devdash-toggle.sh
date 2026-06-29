#!/usr/bin/env bash
# Command-palette action: toggle the dev-dashboard widget.
#
# Auto-discovered by upstream's launcher (services/LauncherSearch.qml loads every
# ~/.config/illogical-impulse/actions/*.sh via a FolderListModel and runs it with
# Quickshell.execDetached([path]) — zero upstream edits). The display name is this
# file's basename without the extension ("devdash-toggle").
#
# Additive + reversible: deleting this file removes the action; upstream's empty
# actions/ dir (auto-recreated by Directories.qml) returns. No upstream category
# is duplicated (this is a distro verb, not clipboard/emoji/math/web-search).
set -u
exec iictl widget toggle devdash
