#!/bin/bash
# Ten-Hut! — Hailo-10H (AI HAT+ 2) verification on Raspberry Pi 5 / Ubuntu 24.04 (kernel 6.8).
#
# Run this AFTER a full power-cycle (poweroff, pull power ~10 s, power on) to load the
# 5.1.1 driver and confirm the SoC firmware boots and the device is usable.
#
#     bash scripts/hailo-verify.sh
#
# It is safe to re-run; loading an already-booted SoC is a no-op.
set -u

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "[0] System"
. /etc/os-release 2>/dev/null
echo "  ${PRETTY_NAME:-?}  kernel $(uname -r)  $(uname -m)"
echo "  uptime: $(uptime -p)"

say "[1] Device present on PCIe (expect 1e60:45c4 = Hailo-10H)"
lspci -nn 2>/dev/null | grep -i hailo || echo "  !! no Hailo device on PCIe — reseat HAT / power-cycle"

say "[2] Kernel taint (bit 7 / value 128 = a prior Oops; other bits are harmless)"
t=$(cat /proc/sys/kernel/tainted)
echo "  taint=$t"
[ $(( t & 128 )) -ne 0 ] && echo "  !! Oops bit set — a crash happened this boot; power-cycle" || echo "  OK: no Oops bit"

say "[3] modprobe.d sanity (must NOT contain 'install ... /bin/false|true')"
if grep -rn "install hailo1x_pci" /etc/modprobe.d/ 2>/dev/null; then
    echo "  !! remove the 'install' line above — it blocks manual modprobe. Keep only 'blacklist'."
else
    echo "  OK: no blocking install line"
fi

say "[4] Load the driver: sudo modprobe hailo1x_pci"
sudo modprobe hailo1x_pci
echo "  modprobe rc=$?"
echo "  loaded version: $(cat /sys/module/hailo1x_pci/version 2>/dev/null || echo '(not loaded)')"

say "[5] Waiting 8 s for SoC firmware boot (stage1 BARs -> stage2 BARs -> stage3 vDMA)..."
sleep 8

say "[6] dmesg (look for 'SOC Firmware Batch loaded successfully')"
sudo dmesg | grep -i hailo | tail -20

say "[7] Fix device permissions if needed (udev MODE=0666)"
if [ -e /dev/hailo0 ]; then
    perms=$(stat -c '%a' /dev/hailo0)
    echo "  /dev/hailo0 mode=$perms"
    if [ "$perms" != "666" ]; then
        echo "  applying udev rule + trigger..."
        sudo udevadm control --reload-rules 2>/dev/null
        sudo udevadm trigger -s hailo_chardev 2>/dev/null
        sleep 1
        echo "  /dev/hailo0 mode=$(stat -c '%a' /dev/hailo0 2>/dev/null)"
    fi
else
    echo "  !! /dev/hailo0 missing — firmware boot failed; see dmesg above"
fi

say "[8] hailortcli fw-control identify (goal: Device Architecture: HAILO10H)"
hailortcli fw-control identify 2>&1 | grep -E "Firmware Version|Device Architecture|Control Protocol|error" | head

say "Done. Success = /dev/hailo0 present + 'Device Architecture: HAILO10H' above."
