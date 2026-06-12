# session-offline.sh — chroot-safe user session helpers.
#
# mkarchiso and Calamares shellprocess both run without a live systemd/logind
# session. `loginctl enable-linger` and `kwriteconfig6` block on D-Bus forever.

ii_systemd_running() {
  [[ -S /run/systemd/private ]] || return 1
  case "$(systemctl is-system-running 2>/dev/null || echo offline)" in
    running|degraded) return 0 ;;
    *) return 1 ;;
  esac
}

# Same effect as `loginctl enable-linger USER` without talking to logind.
ii_enable_linger() {
  local user="$1"
  [[ -n "$user" ]] || return 1
  if ii_systemd_running && command -v loginctl >/dev/null; then
    loginctl enable-linger "$user"
  else
    mkdir -p /var/lib/systemd/linger
    touch "/var/lib/systemd/linger/$user"
  fi
}

# Same effect as `kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle Darkly`.
ii_set_kde_widget_style() {
  local user="$1" home="$2" style="${3:-Darkly}"
  local cfg="$home/.config/kdeglobals"
  [[ -n "$user" && -n "$home" ]] || return 1

  install -d -o "$user" -g "$user" "$home/.config"

  if [[ -f "$cfg" ]] && grep -q '^\[KDE\]' "$cfg"; then
    if grep -q '^widgetStyle=' "$cfg"; then
      sed -i "s/^widgetStyle=.*/widgetStyle=${style}/" "$cfg"
    else
      sed -i "/^\[KDE\]/a widgetStyle=${style}" "$cfg"
    fi
    chown "$user:$user" "$cfg"
  elif [[ -f "$cfg" ]]; then
    printf '\n[KDE]\nwidgetStyle=%s\n' "$style" >> "$cfg"
    chown "$user:$user" "$cfg"
  else
    printf '[KDE]\nwidgetStyle=%s\n' "$style" > "$cfg"
    chown "$user:$user" "$cfg"
  fi
}

# Mirror stdout/stderr to a log file AND keep fd 1 connected for Calamares.
# Plain `exec > >(tee -a log)` drops the parent's stdout capture ("no output").
ii_tee_log() {
  local logfile="$1"
  mkdir -p "$(dirname "$logfile")"
  exec 3>&1
  exec > >(tee -a "$logfile" >&3)
  exec 2>&1
}
