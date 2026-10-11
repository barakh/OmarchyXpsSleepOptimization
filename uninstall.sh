#!/usr/bin/env bash
#
# uninstall.sh - revert the changes made by install.sh:
#   - remove pcie_aspm=force from the kernel cmdline
#   - remove the sleep-tune unit and suspend/resume hooks
#   - disable the Chromium IPU6 camera flag
#
# Run:
#   sudo ./uninstall.sh
# Then reboot.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root:  sudo $0" >&2
  exit 1
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "removing sleep-tune unit and hooks"
if [ -x "$DIR/scripts/omarchy-sleep-tune" ]; then
  bash "$DIR/scripts/omarchy-sleep-tune" uninstall
else
  systemctl disable --now omarchy-sleep-tune.service 2>/dev/null || true
  rm -f /etc/systemd/system/omarchy-sleep-tune.service
  rm -f /usr/lib/systemd/system-sleep/omarchy-sleep-measure
  rm -f /usr/lib/systemd/system-sleep/omarchy-s0ix-measure
  systemctl daemon-reload
  echo "removed"
fi

say "removing forced PCIe ASPM from the kernel cmdline"
bash "$DIR/scripts/aspm-force.sh" off

say "disabling the IPU6 camera Chromium flag"
bash "$DIR/scripts/camera-fix.sh" uninstall

echo "Reboot to apply. log files in /var/log are left in place."
