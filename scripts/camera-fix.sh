#!/usr/bin/env bash
#
# camera-fix.sh - make the internal IPU6 (MIPI) webcam visible to PipeWire and
# Chromium on the Dell XPS 9320 running Omarchy (Wayland/Hyprland).
#
# Symptom this fixes:
#   Chromium cannot find the internal camera even though libcamera can use it
#   (`cam -l` lists "Internal front camera", `qcam` shows a preview).
#
# Cause:
#   Chromium on Wayland reaches cameras through PipeWire. The IPU6 sensor
#   (ov01a10) is a MIPI/raw-Bayer camera, not a V4L2/UVC camera, so Chromium's
#   direct V4L2 path cannot use it. WirePlumber is supposed to expose it to
#   PipeWire via libcamera, but the libcamera SPA plugin is missing (ships in
#   the package "pipewire-libcamera"), so it logs:
#     s-monitors-libcamera: PipeWire's libcamera SPA plugin is missing or broken.
#   With no PipeWire camera node, Chromium shows no camera at all.
#
# Usage:
#   sudo ./camera-fix.sh status      # show current state (safe, read-only)
#   sudo ./camera-fix.sh install     # install plugin + enable Chromium flag
#   sudo ./camera-fix.sh uninstall   # revert the Chromium flag (keeps package)
#
set -euo pipefail

PKG=pipewire-libcamera
SPA_PLUGIN=/usr/lib/spa-0.2/libcamera/libspa-libcamera.so
FLAG=WebRtcPipeWireCamera

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 $*"; }

# The Chromium flag lives in the *desktop user's* home, and install.sh runs as
# root, so figure out which user to edit.
target_user() {
  local u=${SUDO_USER:-}
  if [ -n "$u" ] && [ "$u" != root ]; then echo "$u"; return 0; fi
  command -v loginctl >/dev/null || return 1
  loginctl list-users --no-legend 2>/dev/null | awk '$1 != 0 {print $2; exit}'
}

user_home()  { getent passwd "$1" | cut -d: -f6; }
flags_file() { printf '%s/.config/chromium-flags.conf' "$(user_home "$1")"; }

enable_flag() {
  local user=$1 file=$2
  install -d -m 755 "$(dirname "$file")"
  [ -e "$file" ] || { install -m 644 /dev/null "$file"; }
  if grep -q -- "$FLAG" "$file"; then
    info "already enabled in $file"
  elif grep -q -- '--enable-features=' "$file"; then
    sed -i -E "s|^(--enable-features=[^[:space:]]*)|\1,$FLAG|" "$file"
    info "enabled $FLAG in $file"
  else
    printf -- '--enable-features=%s\n' "$FLAG" >> "$file"
    info "added line to $file"
  fi
  chown "$user" "$file"
}

disable_flag() {
  local user=$1 file=$2
  [ -e "$file" ] || { info "no $file"; return 0; }
  sed -i -E "s|,?$FLAG||g" "$file"
  chown "$user" "$file"
  info "removed $FLAG from $file"
}

restart_user_services() {
  local user=$1 uid
  uid=$(id -u "$user")
  command -v systemctl >/dev/null || return 0
  if runuser -u "$user" -- env \
       XDG_RUNTIME_DIR="/run/user/$uid" \
       DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
       systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null; then
    info "restarted wireplumber/pipewire for $user"
  else
    info "could not restart automatically: as $user run 'systemctl --user restart wireplumber pipewire'"
  fi
}

show_cameras() {
  local user=${1:-$(id -un)} uid out
  command -v wpctl >/dev/null || { info "wpctl not available"; return 0; }
  uid=$(id -u "$user" 2>/dev/null) || { info "unknown user: $user"; return 0; }
  if [ "$(id -u)" -eq 0 ]; then
    out=$(runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            wpctl status 2>/dev/null || true)
  else
    out=$(wpctl status 2>/dev/null || true)
  fi
  printf '%s\n' "$out" \
    | sed -n '/Video/,/Settings/p' \
    | sed -n '/Sources/,/Filters/p' \
    | sed 's/^/   /'
}

cmd_status() {
  local user file
  user=$(target_user || true)

  say "pipewire-libcamera"
  printf '   package:    %s\n' "$(pacman -Q "$PKG" 2>/dev/null || echo 'not installed')"
  printf '   spa plugin: %s\n' "$([ -e "$SPA_PLUGIN" ] && echo "$SPA_PLUGIN" || echo 'MISSING')"

  say "pipewire camera"
  show_cameras "${user:-$(id -un)}"

  say "chromium flag ($FLAG)"
  if [ -n "$user" ]; then
    file=$(flags_file "$user")
    printf '   user: %s\n' "$user"
    printf '   file: %s\n' "$file"
    if [ -r "$file" ]; then
      printf '   %s\n' "$(grep -- "$FLAG" "$file" || echo "not set")"
    else
      printf '   not set (%s missing)\n' "$file"
    fi
  else
    printf '   could not determine the desktop user\n'
  fi
}

cmd_install() {
  need_root install
  local user file
  user=$(target_user) || die "cannot determine the desktop user (set SUDO_USER)"
  file=$(flags_file "$user")

  say "install $PKG"
  if pacman -Q "$PKG" >/dev/null 2>&1; then
    info "already installed ($(pacman -Q "$PKG"))"
  else
    pacman -S --needed --noconfirm "$PKG"
    info "installed"
  fi

  say "enable Chromium PipeWire camera for $user"
  enable_flag "$user" "$file"

  say "restart pipewire"
  restart_user_services "$user"

  say "camera node"
  show_cameras "$user"
  echo
  echo "Relaunch Chromium to pick up the flag, then test the camera."
}

cmd_uninstall() {
  need_root uninstall
  local user file
  user=$(target_user) || die "cannot determine the desktop user (set SUDO_USER)"
  file=$(flags_file "$user")

  say "disable the Chromium PipeWire camera flag"
  disable_flag "$user" "$file"

  echo
  echo "$PKG is left installed (other PipeWire camera apps need it);"
  echo "remove it with:  pacman -R $PKG"
  echo "Relaunch Chromium to apply."
}

case "${1:-}" in
  status)    cmd_status ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  *)         sed -n '2,23p' "$0"; exit 1 ;;
esac
