#!/bin/bash
# Installer for zima-fan on a ZimaCube 2 Pro running ZimaOS.
# Run as root ON the ZimaCube itself: sudo ./install.sh
set -euo pipefail

BUS=0
ADDR=0x69

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo ./install.sh)"; exit 1; }
command -v /usr/sbin/i2cget >/dev/null || { echo "i2c-tools not found"; exit 1; }

# Read-only probe: make sure the fan MCU is where we expect it before
# installing anything. NAK here means a different board/revision — abort.
echo "probing fan MCU at bus ${BUS}, address ${ADDR}..."
if ! /usr/sbin/i2cget -y $BUS $ADDR 0x04 i 8 >/dev/null 2>&1; then
    echo "no response from ${ADDR} on bus ${BUS}; not installing." >&2
    echo "run 'i2cdetect -y -r ${BUS}' and check where (and if) 0x69 shows up." >&2
    exit 1
fi
echo "MCU found. current mailbox: $(/usr/sbin/i2cget -y $BUS $ADDR 0x04 i 8)"

mkdir -p /opt/zima-fan
install -m 0755 "$(dirname "$0")/fan-control.sh" /opt/zima-fan/fan-control.sh
install -m 0644 "$(dirname "$0")/zima-fan.service" /etc/systemd/system/zima-fan.service
systemctl daemon-reload
systemctl enable --now zima-fan.service

sleep 3
systemctl --no-pager --lines=0 status zima-fan.service
echo
echo "done. mailbox now: $(/usr/sbin/i2cget -y $BUS $ADDR 0x04 i 8)"
echo "note: a ZimaOS update may remove this service (RAUC A/B rootfs)."
echo "if the fan ever goes back to loud-by-default, just re-run this installer."
