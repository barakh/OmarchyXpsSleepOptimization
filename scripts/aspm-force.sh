#!/usr/bin/env bash
#
# aspm-force.sh - force PCIe ASPM on, which is required for S0ix (s2idle) on
# machines whose ACPI FADT declares "the system doesn't support PCIe ASPM".
#
# Symptom this fixes:
#   /sys/kernel/debug/pmc_core/slp_s0_residency_usec stays at 0 and dmesg says
#     ACPI FADT declares the system doesn't support PCIe ASPM, so disable it
#   With ASPM disabled the PCH never gates, the PLLs never turn off and the SoC
#   never reaches S0ix -> battery drains several %/h while suspended.
#
# Usage:
#   sudo ./aspm-force.sh status        # show current state (safe, read-only)
#   sudo ./aspm-force.sh on            # add pcie_aspm=force to the kernel cmdline
#   sudo ./aspm-force.sh off           # remove it again
#   sudo ./aspm-force.sh restore-usb   # rebind xHCI (only if a bisect unbound it)
#
# Supports Limine (Omarchy), GRUB and systemd-boot. A reboot is required for
# "on"/"off" to take effect.
#
set -euo pipefail

PARAM="pcie_aspm=force pcie_aspm.policy=powersupersave"
POLICY=/sys/module/pcie_aspm/parameters/policy
LIMINE_CONF=/etc/default/limine
GRUB_CONF=/etc/default/grub
SDBOOT_CMDLINE=/etc/kernel/cmdline
MARK="# managed by omarchy-aspm-force"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 $*"
}

detect_bootloader() {
  if [ -f "$LIMINE_CONF" ]; then echo limine
  elif [ -f "$GRUB_CONF" ]; then echo grub
  elif [ -f "$SDBOOT_CMDLINE" ] || [ -d /boot/loader/entries ]; then echo systemd-boot
  else echo unknown
  fi
}

backup() {
  local f=$1
  [ -f "$f" ] || return 0
  cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
}

regen() {
  case "$(detect_bootloader)" in
    limine)
      command -v limine-update >/dev/null || die "limine-update not found"
      limine-update
      ;;
    grub)
      command -v grub-mkconfig >/dev/null || die "grub-mkconfig not found"
      if   [ -d /boot/grub ];  then grub-mkconfig -o /boot/grub/grub.cfg
      elif [ -d /boot/grub2 ]; then grub-mkconfig -o /boot/grub2/grub.cfg
      else die "no /boot/grub or /boot/grub2 found"; fi
      ;;
    systemd-boot)
      if   command -v reinstall-kernels >/dev/null; then reinstall-kernels
      elif command -v mkinitcpio >/dev/null;       then mkinitcpio -P
      else die "neither reinstall-kernels nor mkinitcpio found"; fi
      ;;
    *) die "unsupported bootloader";;
  esac
}

# --- Limine -------------------------------------------------------------------
limine_on() {
  backup "$LIMINE_CONF"
  if grep -qF "$MARK" "$LIMINE_CONF"; then
    info "already enabled in $LIMINE_CONF"
  else
    printf '\n%s\nKERNEL_CMDLINE[default]+=" %s"\n' "$MARK" "$PARAM" >> "$LIMINE_CONF"
    info "added to $LIMINE_CONF"
  fi
}

limine_off() {
  backup "$LIMINE_CONF"
  awk -v m="$MARK" '
    $0 == m { skip = 1; next }
    skip == 1 && $0 ~ /pcie_aspm=force/ { skip = 0; next }
    { skip = 0; print }
  ' "$LIMINE_CONF" > "$LIMINE_CONF.tmp" && mv "$LIMINE_CONF.tmp" "$LIMINE_CONF"
  info "removed from $LIMINE_CONF"
}

# --- GRUB ---------------------------------------------------------------------
grub_on() {
  backup "$GRUB_CONF"
  if grep -q 'pcie_aspm=force' "$GRUB_CONF"; then
    info "already enabled in $GRUB_CONF"
  else
    sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"|\1 $PARAM\"|" "$GRUB_CONF"
    info "added to $GRUB_CONF"
  fi
}

grub_off() {
  backup "$GRUB_CONF"
  sed -i -E '/^GRUB_CMDLINE/ s/ ?pcie_aspm=force//g; s/ ?pcie_aspm\.policy=powersupersave//g' "$GRUB_CONF"
  info "removed from $GRUB_CONF"
}

# --- systemd-boot (kernel-install / mkinitcpio) -------------------------------
sdboot_on() {
  [ -f "$SDBOOT_CMDLINE" ] || die "$SDBOOT_CMDLINE not found"
  backup "$SDBOOT_CMDLINE"
  if grep -q 'pcie_aspm=force' "$SDBOOT_CMDLINE"; then
    info "already enabled in $SDBOOT_CMDLINE"
  else
    printf ' %s' "$PARAM" >> "$SDBOOT_CMDLINE"
    info "added to $SDBOOT_CMDLINE"
  fi
}

sdboot_off() {
  [ -f "$SDBOOT_CMDLINE" ] || die "$SDBOOT_CMDLINE not found"
  backup "$SDBOOT_CMDLINE"
  sed -i -E 's/ ?pcie_aspm=force//g; s/ ?pcie_aspm\.policy=powersupersave//g' "$SDBOOT_CMDLINE"
  info "removed from $SDBOOT_CMDLINE"
}

# --- USB restore --------------------------------------------------------------
restore_usb() {
  local d
  for d in 0000:00:14.0 0000:00:0d.0; do
    [ -e "/sys/bus/pci/devices/$d" ] || continue
    if [ -e "/sys/bus/pci/devices/$d/driver" ]; then
      info "$d already bound to $(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver")")"
    elif echo "$d" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null; then
      info "rebound $d to xhci_hcd"
    else
      info "could not rebind $d (a reboot will)"
    fi
  done
}

# --- main ---------------------------------------------------------------------
case "${1:-}" in
  status)
    bl=$(detect_bootloader)
    printf 'bootloader:      %s\n' "$bl"
    printf 'active cmdline:  %s\n' "$(cat /proc/cmdline)"
    [ -r "$POLICY" ] && printf 'aspm policy:     %s\n' "$(cat "$POLICY")" \
                     || printf 'aspm policy:     (pcie_aspm module not loaded)\n'
    case "$bl" in
      limine)       grep -qF "$MARK" "$LIMINE_CONF" && s=enabled || s=disabled ;;
      grub)         grep -q 'pcie_aspm=force' "$GRUB_CONF" && s=enabled || s=disabled ;;
      systemd-boot) grep -q 'pcie_aspm=force' "$SDBOOT_CMDLINE" && s=enabled || s=disabled ;;
      *) s=unknown ;;
    esac
    printf 'config:          %s\n' "$s"
    ;;
  on)
    require_root on
    case "$(detect_bootloader)" in
      limine) limine_on ;;
      grub) grub_on ;;
      systemd-boot) sdboot_on ;;
      *) die "unsupported bootloader (edit your kernel cmdline manually and add: $PARAM)" ;;
    esac
    regen
    echo
    echo "Reboot, then verify:  cat $POLICY   (expect [powersupersave])"
    echo "and test S0ix:        sudo ./s0ix-latch.sh 60"
    ;;
  off)
    require_root off
    case "$(detect_bootloader)" in
      limine) limine_off ;;
      grub) grub_off ;;
      systemd-boot) sdboot_off ;;
      *) die "unsupported bootloader" ;;
    esac
    regen
    echo "Reboot to apply."
    ;;
  restore-usb)
    require_root restore-usb
    restore_usb
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
