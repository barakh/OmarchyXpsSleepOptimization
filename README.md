# Omarchy XPS Sleep Optimization

Fixing **s2idle battery drain** on a Dell XPS 13 Plus (9320) running Omarchy /
Arch Linux. Before: **~0% S0ix residency, 5.9–6.9 %/h** battery loss while
suspended. After: **~99.9% S0ix residency, 0.89 %/h**.

The single change that fixes it is forcing PCIe ASPM on the kernel command line:

```
pcie_aspm=force pcie_aspm.policy=powersupersave
```

Everything else in this repo is helpers, diagnostics and verification.

---

## TL;DR

```sh
git clone <this repo> && cd OmarchyXpsSleepOptimization
sudo ./install.sh
sudo reboot

# verify
cat /sys/module/pcie_aspm/parameters/policy     # expect: ... [powersupersave]
sudo ./scripts/s0ix-latch.sh 60                 # expect: residency > 90%
```

---

## Symptoms

- Laptop loses ~6 %/h of battery while "suspended" (lid closed).
- `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` stays at **0** — the SoC
  never enters S0ix (the real low-power state used by `s2idle`).
- `dmesg` contains:

  ```
  ACPI FADT declares the system doesn't support PCIe ASPM, so disable it
  pcie 10000:e1:00.0: can't override BIOS ASPM; OS doesn't have ASPM control
  ```

- `/sys/module/pcie_aspm/parameters/policy` shows the policy is read-only
  (`[default] ...`).

## Root cause

On this firmware (Dell XPS 9320, BIOS 2.27.0, Alder Lake-P) the ACPI FADT tells
Linux that PCIe ASPM is unsupported, so the kernel disables it. S0ix requires the
PCIe links to enter **L1.2**. Without it:

- the PCH never power-gates,
- the PLLs (`OPIOPLL`, `MainPLL`, `Fast_XTAL_Osc`, ...) never turn off,
- the CPU never asserts `CPU_C10_REQ`,
- so the package never reaches S0ix and the platform burns power in L0.

A driver bisection (unbinding the IPU6 camera and the SOF audio DSP, then USB)
produced **0 % residency with identical status bits** in every case, ruling out
a specific Linux driver — it is a platform/firmware ASPM problem.

`pcie_aspm=force` makes the kernel enable ASPM despite the FADT claim, and
`pcie_aspm.policy=powersupersave` makes it use the most aggressive (L1.2) state.

## Results

Measured with the suspend/resume hook in this repo (real lid-close sleep, on
battery, before/after the fix):

| Date       | Sleep mode | S0ix residency | Drain       |
|------------|-----------|----------------|-------------|
| 2026-10-03 | s2idle    | —              | 5.92 %/h    |
| 2026-10-05 | s2idle    | 0.0 %          | 6.92 %/h    |
| 2026-10-06 | s2idle    | **99.9 %**     | **0.89 %/h** |

The latched PMC status after the fix shows the expected L1.2/PLL-off/gating bits
(`PCIe/USB3.1_Gen2PLL_OFF_STS`, `PCIe_Gen3PLL_OFF_STS`, `OPIOPLL_OFF_STS`, ...)
asserting, and S0ix residency of ~97 % even for a short 60 s `rtcwake` test.

Average draw during the fixed sleep measured **~0.35 W** (~7× better). An 8 h
overnight sleep now costs roughly **7 %** of the battery instead of ~50 %.

> Note: `%/h` is computed as a percentage of *full* charge. This laptop's pack is
> degraded (~72.8 % of design capacity, 39.4 of 54.1 Wh), so the watt figure is
> the more portable number.

## Tested on

- Dell XPS 13 Plus 9320 (Alder Lake-P), BIOS 2.27.0
- Omarchy 4.0.4 (Arch), kernel `7.2.5-3-omarchy`
- `s2idle` only (`/sys/power/mem_sleep` = `[s2idle]`; no S3/deep)

---

## Bonus fix: IPU6 camera not visible to Chromium / PipeWire

The internal webcam on this machine is an IPU6 (MIPI/raw-Bayer) sensor
(`ov01a10`), not a V4L2/UVC camera. Chromium on Wayland reaches cameras through
PipeWire, which in turn gets them from WirePlumber via libcamera. Two things are
missing by default on Omarchy 4.0.4, so Chromium shows **no camera** even though
libcamera itself works (`cam -l` lists "Internal front camera", `qcam` previews):

1. the **`pipewire-libcamera`** package (the libcamera SPA plugin). Without it
   WirePlumber logs
   `s-monitors-libcamera: PipeWire's libcamera SPA plugin is missing or broken.`
   and the camera never appears as a PipeWire source; and
2. Chromium's **PipeWire camera backend** is not enabled.

`scripts/camera-fix.sh` installs the plugin, adds `WebRtcPipeWireCamera` to
`--enable-features` in the desktop user's `~/.config/chromium-flags.conf`, and
restarts WirePlumber/PipeWire. After relaunching Chromium the camera appears as
**"Built-in Front Camera"**.

Verify without Chromium:

```sh
cam -l                     # libcamera: "Internal front camera"
wpctl status               # PipeWire "Sources:" lists Built-in Front Camera
```

`sudo ./scripts/camera-fix.sh uninstall` reverts the Chromium flag (the package
is left installed, since other PipeWire camera apps need it).

---

## What install.sh changes

1. **Kernel cmdline** (via Limine by default; GRUB and systemd-boot are also
   supported by `scripts/aspm-force.sh`):

   ```
   pcie_aspm=force pcie_aspm.policy=powersupersave
   ```

   This is the actual fix and requires a reboot.

2. **`/usr/local/bin/omarchy-sleep-tune`** — a userspace tuner that:
   - enables Wi-Fi power save (`options iwlwifi power_save=1`),
   - runs `powertop --auto-tune` if powertop is installed,
   - re-enables USB wakeups that should stay on,
   - trims ACPI wake sources (disables `TDM0`, `TDM1`; keeps `LID0`/`PBTN`
     so the machine can always be woken).

3. **`/etc/systemd/system/omarchy-sleep-tune.service`** — runs `apply` at boot
   (Arch's powertop package ships no such unit).

4. **Suspend/resume hooks** in `/usr/lib/systemd/system-sleep/`:
   - `omarchy-sleep-measure` logs measured drain per sleep,
   - `omarchy-s0ix-measure` logs S0ix residency per sleep.

   All output goes to `/var/log/omarchy-sleep-tune.log`.

5. Removes a broken legacy `aspm-powersupersave.service` if present.

6. Installs the **`pipewire-libcamera`** package, adds `WebRtcPipeWireCamera` to
   the desktop user's `~/.config/chromium-flags.conf`, and restarts
   WirePlumber/PipeWire so the IPU6 camera shows up in Chromium (see the bonus
   fix above).

### Verify

```sh
# after reboot
cat /sys/module/pcie_aspm/parameters/policy     # [powersupersave]
dmesg | grep -i aspm                            # "PCIe ASPM is forcibly enabled"

# short controlled S0ix test (auto-wakes after 60 s)
sudo ./scripts/s0ix-latch.sh 60

# real sleep: close the lid a few hours, then
omarchy-sleep-tune measure
omarchy-sleep-tune status
```

## Diagnostic scripts

| Script | Purpose |
|---|---|
| `scripts/s0ix-latch.sh [secs]` | Latches `intel_pmc_core` registers across a short sleep and names the block(s) keeping the SoC out of S0ix. |
| `scripts/s0ix-diag.sh [--suspend]` | Read-only dump of PMC/LTR/ASPM/suspend state; `--suspend` adds a 90 s controlled sleep. |
| `scripts/s0ix-bisect.sh [case]` | Unbinds candidate drivers (camera/audio/USB) one at a time and measures residency. Use only if ASPM is *not* the cause. |
| `scripts/aspm-force.sh on\|off\|status\|restore-usb` | Toggle the kernel-cmdline ASPM fix and check state. |
| `scripts/camera-fix.sh install\|uninstall\|status` | Make the IPU6 webcam visible to PipeWire/Chromium (installs `pipewire-libcamera`, sets the Chromium flag). |

## Uninstall

```sh
sudo ./uninstall.sh
sudo reboot
```

## Caveats

- `pcie_aspm=force` **can** destabilise some devices (Wi-Fi, NVMe). It is a
  documented workaround for this firmware bug, but if you see freezes or link
  drops after suspend, revert with `sudo ./uninstall.sh` and reboot.
- Hibernation (`suspend-then-hibernate`) is separate and not handled here.
- If ASPM was not your blocker, `slp_s0_residency_usec` will still be ~0 after
  the fix — run `scripts/s0ix-bisect.sh` to find the real culprit.
- The IPU6 camera logs `auxiliary intel_ipu6.psys.40: Failed to get runtime PM`
  on every resume. It is harmless and does not affect S0ix.

## Background

- `intel_pmc_core` debugfs: `Documentation/ABI/testing/debugfs-pmc-core` in the
  kernel tree (`slp_s0_residency_usec`, `substate_live_status_registers`,
  `ltr_show`, `pch_ip_power_gating_status`, `lpm_latch_mode`).
- Kernel parameter: `pcie_aspm=force`, `pcie_aspm.policy=powersupersave`.
