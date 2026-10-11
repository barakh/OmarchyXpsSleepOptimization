#!/usr/bin/env bash
#
# install.sh - apply the full s2idle fix on this machine:
#   1. force PCIe ASPM via the kernel cmdline (the actual S0ix fix)
#   2. install the sleep-tune helper + systemd unit + suspend/resume hooks
#   3. re-apply userspace tuning (Wi-Fi power save, powertop, wake trimming)
#   4. make the IPU6 webcam visible to PipeWire/Chromium (bonus fix)
#
# Run:
#   sudo ./install.sh
#
# Then REBOOT for the kernel cmdline change to take effect.
#
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root:  sudo $0" >&2
  exit 1
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "preflight"
[ -r /sys/kernel/debug/pmc_core/slp_s0_residency_usec ] \
  && echo "intel_pmc_core: available" \
  || echo "warning: intel_pmc_core not available; S0ix residency cannot be logged"
if grep -q "doesn't support PCIe ASPM" <(dmesg 2>/dev/null || true); then
  echo "firmware: FADT says ASPM unsupported  -> aspm-force is needed"
fi

say "1/4  removing legacy aspm-powersupersave.service (if any)"
if [ -f /etc/systemd/system/aspm-powersupersave.service ]; then
  systemctl disable --now aspm-powersupersave.service 2>/dev/null || true
  mv /etc/systemd/system/aspm-powersupersave.service \
     /etc/systemd/system/aspm-powersupersave.service.disabled
  echo "disabled"
else
  echo "not present"
fi

say "2/4  installing sleep-tune helper + unit + hooks"
bash "$DIR/scripts/omarchy-sleep-tune" install

say "3/4  enabling the IPU6 camera for PipeWire/Chromium"
bash "$DIR/scripts/camera-fix.sh" install

say "4/4  forcing PCIe ASPM on the kernel cmdline"
bash "$DIR/scripts/aspm-force.sh" on

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

Next:
  1. REBOOT.
  2. Verify ASPM is forced:
       cat /sys/module/pcie_aspm/parameters/policy     # expect [powersupersave]
  3. Verify S0ix is reached:
       sudo $DIR/scripts/s0ix-latch.sh 60
  4. Sleep the laptop a few hours, then read the measured drain:
       omarchy-sleep-tune measure
  5. Relaunch Chromium and check the camera (should be "Built-in Front Camera"):
       wpctl status | sed -n '/Sources/,/Filters/p'
EOF
