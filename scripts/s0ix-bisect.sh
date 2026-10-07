#!/usr/bin/env bash
#
# s0ix-bisect.sh - find which device blocks S0ix by unloading candidates one at
# a time and measuring S0ix residency after a short sleep.
#
# Usage:
#   sudo ./s0ix-bisect.sh            # run all cases
#   sudo ./s0ix-bisect.sh camera     # one case:
#        baseline | camera | audio | usb | both
#
# Env:
#   SLEEP=45   seconds per test (default 45)
#
# NOTE: on many machines (including the Dell XPS 9320) every case reports 0%
# even with drivers unbound - that means the blocker is firmware/platform ASPM,
# not a Linux driver, and the fix is aspm-force.sh, not this script.
#
# Everything is reverted after each case. Results -> /var/log/omarchy-s0ix-bisect.log

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root:  sudo $0 [case]" >&2
  exit 1
fi

PMC=/sys/kernel/debug/pmc_core
LOG=/var/log/omarchy-s0ix-bisect.log
SLEEP="${SLEEP:-45}"
ONLY="${1:-all}"

IPU_PCI=0000:00:05.0
IPU_DRV=intel-ipu6
AUD_PCI=0000:00:1f.3
AUD_DRV=sof-audio-pci-intel-tgl
XHCI_A=0000:00:14.0
XHCI_B=0000:00:0d.0

res() { cat "$PMC/slp_s0_residency_usec" 2>/dev/null || echo 0; }

snapshot() {
  cat "$PMC/substate_live_status_registers" 2>/dev/null | sed 's/  */ /g' | \
    grep -E '^(PMC0:)(OPIOPLL_OFF|MainPLL_OFF|Fast_XTAL_Osc_OFF|MC_Ring_Osc_OFF|USB2PLL_OFF|XTAL_USB2PLL_OFF|CSME_PG|xHCI_PG|OPIDMI_PG|LPSS_PG|ADSP_D3|xHCI0_D3|xDCI1_D3|IS_D3|CPU_C10_REQ)' \
    | awk '{printf "   %-38s %s\n", $1, $2}'
}

unbind() { # driver pci
  [ -e "/sys/bus/pci/drivers/$1/$2" ] || { echo "   (skip: $2 not bound to $1)"; return; }
  echo "$2" > "/sys/bus/pci/drivers/$1/unbind" 2>/dev/null && echo "   unbound $2 from $1"
}
rbind() { # driver pci
  echo "$2" > "/sys/bus/pci/drivers/$1/bind" 2>/dev/null && echo "   rebound $2 to $1" || echo "   WARN: could not rebind $2"
}

test_case() {
  local name="$1" do_unbind="$2" do_rebind="$3"
  echo
  echo "================= CASE: $name ================="
  eval "$do_unbind" || true
  sleep 2

  echo 1 > "$PMC/lpm_latch_mode" 2>/dev/null || true
  local a b t0 t1 dur dr pct
  a=$(res); t0=$(date +%s)
  echo "   suspending ${SLEEP}s..."
  rtcwake -m mem -s "$SLEEP" >/dev/null 2>&1
  b=$(res); t1=$(date +%s)
  dur=$((t1 - t0)); dr=$((b - a))
  pct=$(awk -v d="$dr" -v s="$dur" 'BEGIN{printf "%.1f",(s>0?100*d/1000000/s:0)}')

  echo "   >> residency: ${pct}%   (S0ix ${dr}us over ${dur}s)"
  snapshot

  {
    echo "================= CASE: $name ================="
    printf 'residency %s%%  delta %sus over %ss\n' "$pct" "$dr" "$dur"
    snapshot
    echo
  } >> "$LOG"

  echo 0 > "$PMC/lpm_latch_mode" 2>/dev/null || true
  sleep 2
  eval "$do_rebind" || true
  sleep 2
}

echo "results -> $LOG"
[ "$ONLY" = all ] && : > "$LOG"

run_case() {
  local key="$1"
  [ "$ONLY" = all ] || [ "$ONLY" = "$key" ] || return 0
  case "$key" in
    baseline) test_case "baseline (nothing changed)" ":" ":" ;;
    camera)   test_case "camera IPU6 unbound" \
                "unbind $IPU_DRV $IPU_PCI" \
                "rbind $IPU_DRV $IPU_PCI" ;;
    audio)    test_case "audio DSP (SOF) unbound" \
                "unbind $AUD_DRV $AUD_PCI" \
                "rbind $AUD_DRV $AUD_PCI" ;;
    usb)      test_case "USB xHCI unbound" \
                "unbind xhci_hcd $XHCI_A; unbind xhci_hcd $XHCI_B" \
                "rbind xhci_hcd $XHCI_A; rbind xhci_hcd $XHCI_B" ;;
    both)     test_case "camera + audio unbound" \
                "unbind $IPU_DRV $IPU_PCI; unbind $AUD_DRV $AUD_PCI" \
                "rbind $IPU_DRV $IPU_PCI; rbind $AUD_DRV $AUD_PCI" ;;
  esac
}

run_case baseline
run_case camera
run_case audio
run_case usb
run_case both

echo
echo "================= SUMMARY ================="
grep -E '^=========|^residency' "$LOG" 2>/dev/null | sed 's/=================//g'
echo
echo "A case that reports residency > 0% identifies the blocker."
echo "The first candidate with nonzero residency is the one to disable permanently."
echo "If every case is still 0%, the blocker is platform/firmware ASPM: run aspm-force.sh on."
