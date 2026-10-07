#!/usr/bin/env bash
#
# s0ix-diag.sh - find out what prevents S0ix on an Intel laptop.
#
# Usage:
#   sudo ./s0ix-diag.sh            # read-only dump
#   sudo ./s0ix-diag.sh --suspend  # + 90s controlled sleep
#
# If the S0ix residency counter is 0us the SoC never entered deep idle.
# intel_pmc_core's ltr_show / pch_ip_power_gating_status show which IP block is
# keeping the platform awake. Everything is written to:
#   /var/log/omarchy-s0ix-diag.log
#
# The --suspend run uses rtcwake (RTC alarm) so no keypress is needed to resume.
# The screen will blank and the session may lock for ~90 seconds.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root:  sudo $0" >&2
  exit 1
fi

PMC=/sys/kernel/debug/pmc_core
LOG=/var/log/omarchy-s0ix-diag.log
SLEEP_SECS=90

section() { printf '\n===== %s =====\n' "$*"; }
res_us()  { cat "$PMC/slp_s0_residency_usec" 2>/dev/null || echo 0; }

run_dump() {
  section "when"
  date; printf 'booted: '; uptime -s
  section "sleep mode"
  cat /sys/power/mem_sleep 2>/dev/null
  section "suspend stats"
  for f in /sys/power/suspend_stats/*; do printf '%s: %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"; done
  section "kernel cmdline"
  cat /proc/cmdline
  section "PCIe ASPM policy"
  cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null
  section "pmc_core files present"
  ls -1 "$PMC" 2>/dev/null || echo "intel_pmc_core debugfs NOT available"
  section "S0ix counter live check (t0, t0+5s)"
  if [ -r "$PMC/slp_s0_residency_usec" ]; then
    a=$(res_us); sleep 5; b=$(res_us)
    echo "t0=${a}us  t1=${b}us  delta=$((b - a))us"
  else
    echo "slp_s0_residency_usec missing"
  fi
  local f
  for f in substate_residencies substate_status ltr_show ltr_ignore pch_ip_power_gating_status; do
    if [ -r "$PMC/$f" ]; then section "$f"; cat "$PMC/$f"; fi
  done
  section "last suspend/resume kernel messages"
  dmesg 2>/dev/null | grep -iE "suspend|s2idle|S0ix|LTR|aspm|wake|GPE|failed|VMD|nvme" | tail -80
}

run_suspend_test() {
  section "controlled sleep test (${SLEEP_SECS}s via rtcwake)"
  if [ ! -x /usr/bin/rtcwake ]; then echo "rtcwake not installed"; return; fi
  echo 1 > /sys/power/pm_debug_messages 2>/dev/null || echo "pm_debug_messages not writable"
  local a b t0 t1
  a=$(res_us); t0=$(date +%s)
  echo "suspending now - do not touch the machine..."
  rtcwake -m mem -s "$SLEEP_SECS"
  b=$(res_us); t1=$(date +%s)
  local dur=$((t1 - t0)) dr=$((b - a))
  local pct
  pct=$(awk -v d="$dr" -v s="$dur" 'BEGIN{printf "%.1f", (s>0 ? 100*d/1000000/s : 0)}')
  echo "asleep ${dur}s, S0ix delta=${dr}us -> residency ${pct}%"
  section "pmc_core state after sleep test"
  local f
  for f in slp_s0_residency_usec substate_residencies pch_ip_power_gating_status ltr_show; do
    if [ -r "$PMC/$f" ]; then printf '\n-- %s --\n' "$f"; cat "$PMC/$f"; fi
  done
  echo 0 > /sys/power/pm_debug_messages 2>/dev/null
}

{
  run_dump
  [ "${1:-}" = --suspend ] && run_suspend_test
  section "done"
  date
} 2>&1 | tee "$LOG"

printf '\nFull output saved to %s\n' "$LOG"
echo
cat <<'EOF'
How to read it:
  * "ltr_show"  -> each IP block's latency tolerance and whether it is MET.
                   An unmet/high requirement names the device keeping the SoC
                   out of S0ix.
  * "pch_ip_power_gating_status" -> blocks that stay ON after resume are unhidden.
  * "substate_residencies" -> which S0ix substates (if any) were reached.
  * If the log shows "ACPI FADT declares the system doesn't support PCIe ASPM",
    run aspm-force.sh on - that is usually the whole fix.
EOF
