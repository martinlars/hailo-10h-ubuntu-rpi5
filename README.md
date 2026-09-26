# 🫡 Ten-Hut! — Hailo-10H (AI HAT+ 2) on Raspberry Pi 5 + **Ubuntu 24.04 / kernel 6.8**

> *"Ten-Hut"* → **10H**, standing to attention on the wrong OS. 🎖️

A working, reproducible install for the **Hailo-10H** accelerator (marketed as the
**"Raspberry Pi AI HAT+ 2"**, PCI ID `1e60:45c4`) on **Ubuntu Server 24.04.3 LTS**
with the stock Raspberry Pi kernel **6.8.0-1065-raspi** — **without** reflashing to
Raspberry Pi OS.

The vendor and every guide out there say Hailo-10H needs **Raspberry Pi OS Trixie
(kernel ≥ 6.12)**. That is the *supported* path, but it is **not the only one that
works**. This repo documents the exact steps, the traps, and the reasoning that got a
Hailo-10H to `Device Architecture: HAILO10H` on Ubuntu 6.8.

```
$ hailortcli fw-control identify
Control Protocol Version: 2
Firmware Version: 5.1.1 (release,app)
Device Architecture: HAILO10H
```

> ⚠️ **Unsupported / best-effort.** This is not endorsed by Hailo or Raspberry Pi. It
> worked on the exact stack below. If you can reflash to Raspberry Pi OS Trixie and run
> `sudo apt install hailo-h10-all`, that is the easy, supported route — see
> [When to just use Raspberry Pi OS](#when-to-just-use-raspberry-pi-os). Use this guide
> when you are stuck on Ubuntu and want the thing to work anyway.

---

## TL;DR

The whole problem is **version matching + a cold power-cycle**. The Hailo-10H has an
on-chip bootloader (`pci_ep`) permanently flashed at **5.1.1** with no public updater.
Feed it a **5.1.1** host driver, **5.1.1** firmware and **5.1.1** userspace and it boots.
Feed it anything newer (5.3.0 / 5.4.0) and the SoC boot crashes the kernel.

```bash
# 1. Toolchain
sudo apt update
sudo apt install -y dkms build-essential linux-headers-$(uname -r) git curl

# 2. Get the matched 5.1.1 packages (driver deb ships firmware + DKMS source)
mkdir -p ~/hailo-debs-5.1.1 && cd ~/hailo-debs-5.1.1
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort-pcie-driver_5.1.1_all.deb
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort_5.1.1_arm64.deb

# 3. Install driver (DKMS build + firmware + udev rule) then userspace
sudo apt install -y ./hailort-pcie-driver_5.1.1_all.deb
sudo apt install -y ./hailort_5.1.1_arm64.deb

# 4. FULL POWER-CYCLE (not a reboot): sudo poweroff, pull power ~10 s, power on.

# 5. Verify
hailortcli fw-control identify        # -> Device Architecture: HAILO10H
```

If step 3's `modprobe` inside the deb hits a crash on kernel 6.8, use the
[manual build path](#path-b-manual-source-build-what-we-actually-did) instead — it is
identical in result but lets you stage everything, blacklist auto-load, and load the
driver by hand *after* the power-cycle. That is what we actually did.

---

## Verified environment

| Item | Value |
|------|-------|
| Board | Raspberry Pi 5 Model B |
| OS | Ubuntu 24.04.3 LTS (arm64) |
| Kernel | `6.8.0-1065-raspi` |
| Accelerator | Hailo-10H, `lspci` → `1e60:45c4`, board **SKU-ID 6** |
| PCIe link | Gen3 x1, up |
| Working triple | driver **5.1.1** + firmware **5.1.1** + HailoRT **5.1.1** |
| Result | `/dev/hailo0`, `Device Architecture: HAILO10H` |

Check your board matches:

```bash
lspci -nn | grep -i hailo
# 0000:01:00.0 Co-processor [0b40]: Hailo Technologies Ltd. Device [1e60:45c4] (rev 01)
```

`45c4` = Hailo-**10H**. If you see `1e60:2864` you have a **Hailo-8/8L** (AI Kit / AI HAT+),
which is a **completely different** software stack — this guide does not apply, use
`hailo-all` on Raspberry Pi OS instead.

---

## Why the "obvious" approach crashes (and the fix)

Our first attempt built the driver from the newest git tag (**v5.4.0**) and downloaded
matching **5.4.0** firmware. On `modprobe` the SoC boot got partway and then the kernel
**Oops**ed:

```
hailo1x ... Writing file customer_certificate.bin ... OK
hailo1x ... Writing file scu_fw.bin              ... OK
hailo1x ... Board SKU-ID is: 6
hailo1x ... Writing file u-boot-6.dtb.signed     ... OK
Unable to handle kernel paging request ...
pc : kfree ...
  write_firmware_and_wait_completion
  hailo_activate_board
  hailo_pcie_probe   (kworker)
# modprobe stuck in D-state, kernel tainted, no /dev/hailo0
```

### The SoC boot has three stages

The Hailo-10H is a full SoC. `load_soc_firmware()` in `linux/pcie/src/pcie.c` boots it
in three stages:

| Stage | Files | Transport |
|-------|-------|-----------|
| 1 | `customer_certificate.bin`, `scu_fw.bin` | PCIe BARs |
| 2 | `u-boot-<SKU>.dtb.signed` (SKU-6 → `u-boot-6`) | PCIe BARs |
| 3 | `u-boot-spl`, `u-boot-tfa.itb`, `fitImage`, `image-fs` | **vDMA** |

The Oops is in **stage 3, the vDMA path** (`pcie_write_firmware_batch_over_dma` →
allocate scatter-gather → `kfree` of the pages array). That path is what fails.

### Root cause: it was **firmware mismatch**, not the kernel

The popular theory is "kernel 6.8 is below the 6.12 floor, so the vDMA path is broken."
We tested that directly and it is **wrong for the build, and wrong as the whole story**:

- The driver source `pcie.c` is **byte-identical** between git tags `v5.1.1` and
  `v5.4.0` (`diff -q` reports no difference). So the crash is not a code bug that a
  newer tag fixes.
- The 5.1.1 module **compiles cleanly** against kernel 6.8 headers.
- With **5.1.1 firmware** in place, stage 3 (the same vDMA code that Oopsed under 5.4.0)
  completes in ~2.1 s and `/dev/hailo0` appears.

The on-chip `pci_ep` bootloader is flash-resident at **5.1.1** and there is no public
updater. A host stack newer than 5.1.1 produces a firmware image the on-chip bootloader
rejects mid-transfer, and the driver's cleanup path faults. **Match the on-chip 5.1.1
and it boots.** (Kernel ≥ 6.12 is still the *supported* floor and may matter for other
firmware combos — but it was not what blocked us.)

> ❌ **Dead end we chased so you don't have to:** `force_hailo_pcie_boot_mode_over_bars`
> does **not** exist as a module parameter in any 5.x driver. The only params in 5.1.1
> are `no_power_mode`, `force_desc_page_size`, `force_hailo10h_legacy_mode`
> (emulator-only), `support_soft_reset`, `o_dbg`. There is no "boot over BARs" escape
> hatch for stage 3.

---

## Path A: install from the official .deb packages (recommended)

This is the clean route. The **driver deb ships everything the kernel side needs**:
firmware blobs, DKMS source, and the udev rule.

```bash
sudo apt update
sudo apt install -y dkms build-essential linux-headers-$(uname -r) git curl

mkdir -p ~/hailo-debs-5.1.1 && cd ~/hailo-debs-5.1.1
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort-pcie-driver_5.1.1_all.deb
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort_5.1.1_arm64.deb

sudo apt install -y ./hailort-pcie-driver_5.1.1_all.deb   # DKMS build + firmware + udev
sudo apt install -y ./hailort_5.1.1_arm64.deb             # hailortcli + libhailort
```

What the driver deb's `postinst` does: `make install_dkms` (build + install the module),
drop firmware into `/lib/firmware/hailo/hailo10h/`, install the udev rule, then
`modprobe -rq hailo1x_pci; modprobe hailo1x_pci`.

**Then the critical step — a full power-cycle, not a reboot** (see
[Why a power-cycle](#why-a-power-cycle-and-not-a-reboot)):

```bash
sudo poweroff
# physically remove power for ~10 seconds, then power back on
hailortcli fw-control identify
```

> If the `postinst`'s `modprobe` triggers the stage-3 crash on your kernel *before* you
> get a chance to power-cycle, the module will hang in D-state and you'll need a
> power-cycle to clear it anyway. To avoid loading the driver until *after* a cold boot,
> use Path B.

The download page pattern is `https://dev-public.hailo.ai/<YYYY_MM>/Hailo10/<file>`;
5.1.1 lives under `2025_12/`. The Raspberry Pi apt repo also caps HailoRT at 5.1.1, so
`sudo apt install hailo-h10-all` on Pi OS installs the same version — see
[the apt route](#when-to-just-use-raspberry-pi-os).

---

## Path B: manual source build (what we actually did)

This path stages the driver, keeps it from auto-loading until *after* the cold boot, and
loads it by hand. It's more steps but gives you full control and a clean recovery if
stage 3 still crashes. It produces the identical result to Path A.

### B1. Toolchain + driver source

```bash
sudo apt update
sudo apt install -y dkms build-essential linux-headers-$(uname -r) git curl

git clone https://github.com/hailo-ai/hailort-drivers.git ~/hailort-drivers
cd ~/hailort-drivers
git checkout v5.1.1          # MUST match on-chip pci_ep 5.1.1; do NOT use master/v5.4.0
```

### B2. Firmware 5.1.1

The upstream `download_firmware_hailo10h.sh` was removed in PR #64 (2026-09-15) as the
project moved to packaged installs. The reliable source of the 5.1.1 firmware blobs is
the **driver deb** — extract them from it:

```bash
mkdir -p ~/hailo-debs-5.1.1 && cd ~/hailo-debs-5.1.1
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort-pcie-driver_5.1.1_all.deb
dpkg-deb -x hailort-pcie-driver_5.1.1_all.deb extract/

sudo mkdir -p /lib/firmware/hailo/hailo10h
sudo cp extract/lib/firmware/hailo/hailo10h/* /lib/firmware/hailo/hailo10h/
```

You should now have these under `/lib/firmware/hailo/hailo10h/`:

```
customer_certificate.bin  fitImage  image-fs  scu_fw.bin
u-boot-0.dtb.signed  u-boot-1.dtb.signed  u-boot-3.dtb.signed
u-boot-4.dtb.signed  u-boot-5.dtb.signed  u-boot-6.dtb.signed
u-boot-default.dtb.signed  u-boot-spl.bin
```

### B3. Build + install the DKMS module

```bash
cd ~/hailort-drivers/linux/pcie
sudo make install_dkms        # builds hailo1x_pci 5.1.1, installs to /lib/modules/.../updates/dkms
sudo depmod -a
dkms status | grep hailo      # hailo1x_pci/5.1.1, <kernel>, aarch64: installed
```

### B4. Block auto-load until after the cold boot

Because the module has a PCI alias for `45c4`, it will try to load on boot. If it still
crashes, that hangs your boot. Block it for now (bare `blacklist`, so you can still
`modprobe` by hand):

```bash
echo 'blacklist hailo1x_pci' | sudo tee /etc/modprobe.d/hailo-blacklist.conf
```

> **Trap:** if you (or an earlier attempt) also created a file with
> `install hailo1x_pci /bin/false` or `/bin/true`, that line **blocks even a manual
> `modprobe`** with `Error running install command`. Remove any such line — keep only
> `blacklist`. Check with: `grep -rn hailo /etc/modprobe.d/`.

### B5. Userspace runtime

```bash
cd ~/hailo-debs-5.1.1
curl -fLO https://dev-public.hailo.ai/2025_12/Hailo10/hailort_5.1.1_arm64.deb
sudo apt install -y ./hailort_5.1.1_arm64.deb
hailortcli --version          # HailoRT-CLI version 5.1.1
```

### B6. Power-cycle, then load by hand

```bash
sudo poweroff
# pull power ~10 s, power on, log back in
sudo modprobe hailo1x_pci
sudo dmesg | grep -i hailo | tail
```

Expected healthy log:

```
hailo1x: Init module. driver version 5.1.1
hailo1x ...: Board SKU-ID is: 6
hailo1x ...: Firmware batch programming completed for stage 2
hailo1x ...: vDMA transfer completed, triggering boot
hailo1x ...: SOC Firmware Batch loaded successfully
hailo1x ...: Firmware loaded in 2104 ms
hailo1x ...: Probing: Added board 1e60-45c4, /dev/hailo0
```

### B7. Fix permissions (udev) — otherwise `hailortcli` fails without sudo

If you loaded the module by hand, the udev rule may not have fired, leaving
`/dev/hailo0` as `crw------- root root` (0600). Then `hailortcli` (running as your user)
fails:

```
[HailoRT] [error] CHECK failed - Failed to open device file /dev/hailo0 with error 13
[HailoRT] ... HAILO_DRIVER_OPERATION_FAILED(36)
```

Install the rule (ships in the driver deb) and re-trigger:

```bash
sudo cp ~/hailo-debs-5.1.1/extract/lib/udev/rules.d/51-hailo-udev.rules \
        /lib/udev/rules.d/51-hailo-udev.rules
sudo udevadm control --reload-rules
sudo udevadm trigger -s hailo_chardev
ls -l /dev/hailo0             # crw-rw-rw-
```

The rule is one line:

```
SUBSYSTEM=="hailo_chardev", MODE="0666"
```

### B8. Enable auto-load (optional)

Once you trust it, remove the blacklist so the driver loads on every boot:

```bash
sudo rm -f /etc/modprobe.d/hailo-blacklist.conf
sudo depmod -a
```

The PCI alias `45c4 → hailo1x_pci` will now load it automatically. Firmware stays
latched in the SoC across warm reboots, so subsequent loads log
`SOC Firmware batch was already loaded / Firmware loaded in 0 ms`.

---

## Verify

```bash
hailortcli scan
# Hailo Devices:
# [-] Device: 0000:01:00.0

hailortcli fw-control identify
# Control Protocol Version: 2
# Firmware Version: 5.1.1 (release,app)
# Device Architecture: HAILO10H
```

Or run the bundled script, which checks every step and decodes the kernel taint:

```bash
./scripts/hailo-verify.sh
```

---

## Why a power-cycle and not a reboot?

The Hailo-10H **latches its firmware/boot state across warm resets**. After a failed
load the SoC can be in a wedged state that a `reboot` does **not** clear — and the
`modprobe` that hit the Oops goes into a permanent uninterruptible **D-state** that only
a full power removal clears. Always do `sudo poweroff` → pull power ~10 s → power on
between attempts. A warm `reboot` is not enough.

---

## Typical problems (symptom → cause → fix)

| Symptom | Cause | Fix |
|--------|-------|-----|
| `modprobe: Error running install command '/bin/false'` | a `install hailo1x_pci /bin/false` line in `/etc/modprobe.d/` | remove that line; keep only bare `blacklist` (§B4) |
| Kernel Oops / `kfree` in `write_firmware_and_wait_completion`, modprobe stuck in D | firmware/driver newer than on-chip 5.1.1 | use the **5.1.1** triple; power-cycle |
| Boot hangs / SoC wedged, warm reboot doesn't help | SoC latched a bad boot state; D-state modprobe won't die | full **power-cycle** (`poweroff`, pull power ~10 s) — never just `reboot` |
| `Failed to open device file /dev/hailo0 with error 13` | `/dev/hailo0` is 0600, you're not root | install udev rule `MODE="0666"` (§B7) |
| `hailortcli` prints `HAILO_DRIVER_OPERATION_FAILED(36)` | same permission issue as error 13, or driver not loaded | check `lsmod \| grep hailo` and `ls -l /dev/hailo0` |
| `Failed writing SOC firmware on stage 2`, timeout `-110` | can be PCIe cable / power / a genuinely faulty module | reseat FFC/HAT, ensure a 5 A PSU, try another module |
| `driver_compatible=false` / `EINVAL` on every ioctl | host stack > 5.1.1 vs on-chip pci_ep 5.1.1 | pin everything to 5.1.1 |
| Works, then breaks after a kernel update | DKMS rebuilds automatically, but SoC may need a cold boot | `sudo poweroff`, power-cycle |
| `duplicate filename /class/hailo_chardev` (EEXIST -17) | a stale `.ko` in the kernel tree beside the DKMS one | remove both copies, `depmod -a`, reload |
| `no /dev/hailo0` but no crash either | driver blacklisted, or firmware missing from `/lib/firmware/hailo/hailo10h/` | check §B4 blacklist and that firmware files are present |
| `lspci` shows nothing / no `1e60:45c4` | HAT not seated, or PCIe disabled | reseat the FFC ribbon (correct orientation), power-cycle |

---

## Q&A

**Q: Do I really not need Raspberry Pi OS?**
No — this repo is proof it runs on Ubuntu 24.04 / kernel 6.8. That said, Raspberry Pi OS
Trixie + `hailo-h10-all` is the *supported* path and is genuinely easier. Use Ubuntu only
if you have a reason to (existing server, other workloads, can't reflash).

**Q: Isn't kernel 6.8 below the documented 6.12 floor? How does it work?**
The 6.12 floor is the *supported* minimum. In our case the actual blocker was a
**firmware/host version mismatch**, not the kernel: the same stage-3 vDMA code that
Oopsed under a 5.4.0 firmware boots fine under 5.1.1 firmware on 6.8. The kernel version
was a red herring for this specific failure. Newer firmware combinations may still need
≥ 6.12, so don't take this as "6.8 is fine for everything."

**Q: Why exactly 5.1.1? Can I use 5.3.0 / 5.4.0 for newer models or features?**
The Hailo-10H's on-chip bootloader (`pci_ep`) is flashed at **5.1.1** with **no public
updater**. HailoRT enforces a version match between the host driver, userspace, and that
on-chip loader. Anything newer than 5.1.1 gets rejected mid-boot (host driver 5.3.0/5.4.0
→ `driver_compatible=false` / `EINVAL`). The Raspberry Pi apt repo also caps at 5.1.1 for
this reason. So: **5.1.1 across the board, full stop.**

**Q: Why a power-cycle instead of `sudo reboot`?**
The SoC latches firmware/boot state across *warm* resets, and a `modprobe` that hit the
Oops sits in an uninterruptible **D-state** that a reboot can't clear. Only removing power
for ~10 s resets the chip. This bit us hard — a wedged module survived a 1h+ uptime with
no reboot clearing it.

**Q: Is `force_hailo_pcie_boot_mode_over_bars=1` the fix, like some threads suggest?**
No. That parameter **does not exist** in any 5.x driver. We checked the source. Don't
waste time on it. The real fix is the version match + power-cycle.

**Q: `hailortcli` works with `sudo` but not as my user. Why?**
`/dev/hailo0` was created `0600 root:root` because the udev rule didn't fire (common when
you `modprobe` by hand after boot). Install the `51-hailo-udev.rules` file (`MODE="0666"`)
and re-trigger udev — see §B7.

**Q: Will it survive a reboot / kernel upgrade?**
Yes. With the blacklist removed (§B8) the PCI alias auto-loads the driver on boot, and
DKMS rebuilds the module automatically after a kernel upgrade. If the SoC ever wedges,
fall back to a power-cycle.

**Q: `.deb` from `dev-public.hailo.ai` — is that legit / stable?**
Yes, it's Hailo's own public distribution host; the same 5.1.1 packages the Raspberry Pi
apt repo serves. URLs follow `https://dev-public.hailo.ai/<YYYY_MM>/Hailo10/<file>`
(5.1.1 lives under `2025_12/`). If a link 404s, the month prefix moved — check the
[Hailo Community forum](https://community.hailo.ai/) for the current path.

**Q: Where did `download_firmware_hailo10h.sh` go?**
Removed upstream in PR #64 (2026-09-15) when the project moved to packaged installs. Get
the firmware from the driver `.deb` instead (§B2).

**Q: How do I know it's actually working, not just present?**
`hailortcli scan` shows the PCI device even when firmware failed to boot. The real proof
is `hailortcli fw-control identify` returning `Device Architecture: HAILO10H` and a
firmware version — that requires a fully booted SoC.

**Q: Can I run LLMs / the Hailo model zoo on it now?**
Yes — that's what the 10H (a GenAI-class part) is for. Install the matching
`hailo_gen_ai_model_zoo_5.1.1_arm64.deb` from the same `dev-public.hailo.ai/2025_12/Hailo10/`
directory and use the HailoRT GenAI APIs. (Out of scope for this repo, which only covers
getting the device up.)

**Q: I have a Hailo-8 / AI Kit / AI HAT+ (not "+2"). Does this apply?**
No. Hailo-8/8L is `1e60:2864`, a different driver and stack. Use `hailo-all` on
Raspberry Pi OS. This guide is Hailo-**10H** (`1e60:45c4`) only.

---

## When to just use Raspberry Pi OS

If you can reflash, this is the supported, lowest-risk path — the apt stack is
version-matched to the on-chip **5.1.1** out of the box:

```bash
# On a fresh Raspberry Pi OS Trixie (Debian 13), 64-bit:
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a && sudo reboot
sudo apt install -y dkms                 # dkms MUST be installed BEFORE the Hailo package
sudo apt install -y hailo-h10-all        # NOT hailo-all (that is Hailo-8)
sudo reboot
hailortcli fw-control identify           # Device Architecture: HAILO10H
```

- Use **Trixie**, not Bookworm (Bookworm is not supported for the AI HAT+ 2).
- `hailo-h10-all` (Hailo-10H) and `hailo-all` (Hailo-8) **cannot coexist**.
- `dkms` before the package, or the driver won't build.

The Ubuntu path in this repo exists for when reflashing isn't an option.

---

## Uninstall / cleanup

```bash
sudo modprobe -r hailo1x_pci 2>/dev/null || true
sudo dkms remove hailo1x_pci/5.1.1 --all 2>/dev/null || true
sudo apt remove -y hailort hailort-pcie-driver 2>/dev/null || true
sudo rm -rf /lib/firmware/hailo/hailo10h
sudo rm -f /lib/udev/rules.d/51-hailo-udev.rules /etc/modprobe.d/hailo-blacklist.conf
sudo depmod -a
```

---

## References

- Hailo driver source: <https://github.com/hailo-ai/hailort-drivers> (tag `v5.1.1`)
- HailoRT: <https://github.com/hailo-ai/hailort>
- Official Raspberry Pi AI docs: <https://www.raspberrypi.com/documentation/computers/ai.html>
- 5.1.1 packages (arm64): `https://dev-public.hailo.ai/2025_12/Hailo10/`
  - `hailort-pcie-driver_5.1.1_all.deb` (firmware + DKMS source + udev rule)
  - `hailort_5.1.1_arm64.deb` (hailortcli + libhailort)
- Hailo Community forum: <https://community.hailo.ai/>

## Disclaimer

Provided as-is, no warranty. This is an **unsupported** configuration; you can brick a
boot or waste an evening. Not affiliated with Hailo or Raspberry Pi. All trademarks
belong to their owners.
