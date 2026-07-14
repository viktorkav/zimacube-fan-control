#!/bin/bash
# zima-fan — temperature-based CPU fan control for the ZimaCube 2 Pro
# via the fan MCU on the SMBus (bus 0, address 0x69).
#
# The MCU only has two modes: 0 = factory default (loud), 1 = fixed duty.
# This loop reads the CPU package temperature and adjusts the duty cycle.
# On exit it returns the MCU to mode 0: loud, but thermally safe — the
# failsafe is designed to be audible.

I2CSET=/usr/sbin/i2cset
BUS=0
ADDR=0x69
REG=0x04
INTERVAL=5
REASSERT_CYCLES=12   # rewrite the duty every 60s even if unchanged
EMERGENCY_TEMP=90    # at or above this, ramp up on a single sample
FAST_TEMP=70         # at or above this, 2 consecutive samples are enough
SUSTAIN_SAMPLES=3    # otherwise, require this many consecutive samples before ramping up

set_duty() { # $1 = duty, $2 = temp (for the log line)
    echo "duty -> ${1}% (cpu ${2}C)"
    $I2CSET -y $BUS $ADDR $REG 0x01 "$(printf '0x%02x' "$1")" 0x00 0x00 0x00 0x00 0x01 0x00 i
}

restore_default() {
    $I2CSET -y $BUS $ADDR $REG 0x00 0x00 0x00 0x00 0x00 0x00 0x01 0x00 i
}
trap restore_default EXIT

# find the x86_pkg_temp zone by type (the index can change between kernels)
TEMP_PATH=""
for z in /sys/class/thermal/thermal_zone*; do
    if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ]; then
        TEMP_PATH="$z/temp"
        break
    fi
done
if [ -z "$TEMP_PATH" ]; then
    echo "zima-fan: x86_pkg_temp zone not found; leaving factory default in place" >&2
    exit 1
fi

duty_for() { # $1 = temperature in °C
    if   [ "$1" -ge 90 ]; then echo 100
    elif [ "$1" -ge 80 ]; then echo 90
    elif [ "$1" -ge 70 ]; then echo 75
    elif [ "$1" -ge 60 ]; then echo 55
    elif [ "$1" -ge 50 ]; then echo 40
    else echo 30
    fi
}

last_duty=-1
cycles=0
pending_up=0
while :; do
    t=$(( $(cat "$TEMP_PATH") / 1000 ))
    d=$(duty_for "$t")
    if [ "$d" -gt "$last_duty" ]; then
        # single-sample temp spikes (ZimaOS background bursts reach 70-83°C for
        # ~2s) shouldn't audibly bump the fan: heat only matters if sustained.
        # The CPU's own throttling at 100°C is the hardware backstop.
        if [ "$t" -ge "$EMERGENCY_TEMP" ] || [ "$last_duty" -lt 0 ]; then
            set_duty "$d" "$t" && last_duty=$d
            pending_up=0
        else
            pending_up=$(( pending_up + 1 ))
            need=$SUSTAIN_SAMPLES
            [ "$t" -ge "$FAST_TEMP" ] && need=2
            if [ "$pending_up" -ge "$need" ]; then
                set_duty "$d" "$t" && last_duty=$d
                pending_up=0
            fi
        fi
    elif [ "$d" -lt "$last_duty" ]; then
        pending_up=0
        # ramping down: 3°C hysteresis to avoid oscillating at band edges
        d_hyst=$(duty_for $(( t + 3 )))
        if [ "$d_hyst" -lt "$last_duty" ]; then
            set_duty "$d_hyst" "$t" && last_duty=$d_hyst
        fi
    else
        pending_up=0
        if [ "$cycles" -ge "$REASSERT_CYCLES" ]; then
            # periodic re-assert in case the MCU reset on its own
            set_duty "$d" "$t"
            cycles=0
        fi
    fi
    cycles=$(( cycles + 1 ))
    sleep $INTERVAL
done
