#!/usr/bin/env bash
#
# s0ix-latch.sh - latch the PMC low-power status across suspend so we can see
# what prevented S0ix entry.
#
# Usage:
#   sudo ./s0ix-latch.sh [seconds]
#
# How it works (per intel_pmc_core docs):
#   1. enable lpm_latch_mode so the LPM status registers are frozen during sleep
#   2. rtcwake for N seconds (default 60) - auto wakes, no keypress
#   3. read the latched registers: any status bit that is 0 that should be 1
#      names the IP block keeping the SoC out of S0ix
#
# Output -> /var/log/omarchy-s0ix-latch.log

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root:  sudo $0 [seconds]" >&2
  exit 1
fi

PMC=/sys/kernel/debug/pmc_core
LOG=/var/log/omarchy-s0ix-latch.log
SLEEP_SECS="${1:-60}"

for f in lpm_latch_mode slp_s0_residency_usec substate_live_status_registers; do
  [ -e "$PMC/$f" ] || { echo "missing $PMC/$f" >&2; exit 1; }
done

res() { cat "$PMC/slp_s0_residency_usec" 2>/dev/null || echo 0; }

# The latch write may be "1" or may need an explicit substate; try "1".
if ! echo 1 > "$PMC/lpm_latch_mode" 2>/dev/null; then
  echo "could not enable lpm_latch_mode; reading $(cat "$PMC/lpm_latch_mode" 2>/dev/null)" >&2
  echo "continuing without latch (results less reliable)"
fi
echo "lpm_latch_mode now: $(cat "$PMC/lpm_latch_mode" 2>/dev/null)"
echo 1 > /sys/power/pm_debug_messages 2>/dev/null || true

a=$(res); t0=$(date +%s)
echo "suspending for ${SLEEP_SECS}s..."
rtcwake -m mem -s "$SLEEP_SECS"
b=$(res); t1=$(date +%s)
dur=$(( t1 - t0 )); dr=$(( b - a ))
pct=$(awk -v d="$dr" -v s="$dur" 'BEGIN{printf "%.1f",(s>0?100*d/1000000/s:0)}')

{
  echo "===== result ====="
  printf 'asleep %ss, S0ix delta=%sus -> residency %s%%\n' "$dur" "$dr" "$pct"
  echo
  echo "===== slp_s0_residency_usec (latched) ====="
  cat "$PMC/slp_s0_residency_usec"
  echo
  echo "===== substate_live_status_registers (latched: state during suspend) ====="
  cat "$PMC/substate_live_status_registers"
  echo
  echo "===== pch_ip_power_gating_status ====="
  cat "$PMC/pch_ip_power_gating_status"
  echo
  echo "===== ltr_show ====="
  cat "$PMC/ltr_show"
  echo
  echo "===== suspend/resume dmesg ====="
  dmesg 2>/dev/null | grep -iE "suspend|s2idle|S0ix|LTR|aspm|wake|failed|ipu6|vsc" | tail -60
} 2>&1 | tee "$LOG"

echo 0 > "$PMC/lpm_latch_mode" 2>/dev/null || true
echo 0 > /sys/power/pm_debug_messages 2>/dev/null || true

printf '\nSaved to %s\n' "$LOG"
echo
cat <<'EOF'
How to read the latched block (substate_live_status_registers):
  Look for fields that are 0 which are requirements for S0i2.0, typically:
    OPIOPLL_OFF_STS, MainPLL_OFF_STS, Fast_XTAL_Osc_OFF_STS, MC_Ring_Osc_OFF_STS
    CPU_C10_REQ_STS_0, MPHY_SUS_REQ_STS_22, USB2_SUS_PG_Sys_REQ_STS_10
    *_PG_STS (XHCI/OPIDMI/SPE/SPF/PSF/SBR/FIA should be gated)
  A 0 in one of these = the block still powered/clocked = the S0ix blocker.
EOF
