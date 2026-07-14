# zimacube-fan-control

Temperature-based CPU fan control for the **ZimaCube 2 Pro**, talking directly to the fan MCU over I2C. Fixes the "fan runs loud all the time" behavior after ZimaOS updates.

Tested on: ZimaCube 2 Pro, ZimaOS 1.6.2, kernel 6.18.9, BIOS 5.24 (AMI, 2025-12-10).

## The problem

After a ZimaOS update, the central CPU fan runs loud constantly, even with the system fully idle (CPU at ~40 °C, deep C-states, no I/O). Nothing in ZimaOS or the exposed kernel interfaces controls it:

- No fan appears in hwmon (`sensors` shows temperatures only).
- The five ACPI fan devices (`\_TZ_.FAN0-4`) are all in D3hot with `cur_state=0` — the OS believes every fan is off.
- ZimaOS itself has no fan control (the only "fan" strings in its binaries are NVIDIA GPU APIs).
- The BIOS was not changed by the update.

## The root cause

The fan is driven by a small MCU sitting on the **SMBus (i2c-0, Intel PCH I801) at address `0x69`**. Its power-on default is a loud fixed speed, and nothing in the stock OS ever reconfigures it. So whenever the MCU is at its default (fresh boot after an update, for example), the fan is loud regardless of temperature.

The MCU accepts commands through an 8-byte mailbox at register `0x04` and only understands **two modes**:

| Mode | Meaning |
|------|---------|
| `0x00` | Factory default: loud fixed speed (thermally safe, acoustically terrible) |
| `0x01` | Fixed duty cycle, 0–100, set by the host |

There is no native temperature-following mode: any other mode byte is rejected (the mailbox self-clears to zeros and the fan returns to the loud default). That means a **fixed duty alone is not a safe fix** — set it low and your CPU will cook under load. You need a control loop, which is what this repo provides.

## MCU protocol (as mapped so far)

All access is over `i2c-0`, address `0x69`, no `-f` flag needed (no kernel driver claims the address).

**Mailbox — register `0x04`, 8-byte block write:**

```
byte 0: mode        0x00 = factory default, 0x01 = fixed duty
byte 1: duty        0-100 (0x00-0x64), only used in mode 1
bytes 2-5: 0x00
byte 6: 0x01        constant in all observed commands (command latch?)
byte 7: 0x00
```

Examples:

```sh
# set fixed duty 30%
i2cset -y 0 0x69 0x04 0x01 0x1e 0x00 0x00 0x00 0x00 0x01 0x00 i

# return to factory default (loud but safe)
i2cset -y 0 0x69 0x04 0x00 0x00 0x00 0x00 0x00 0x00 0x01 0x00 i

# read the mailbox back
i2cget -y 0 0x69 0x04 i 8
```

**Other registers (read-only observations):**

| Reg | Value seen | Interpretation |
|-----|-----------|----------------|
| `0x02`–`0x03` | 16-bit LE, ~53k–60k at low duty | Looks like the tach **period** (drops as duty rises); `0x02` alone is just its noisy low byte |
| `0x06` | `0x29` (41) | Temperature in °C, tracks CPU package temp |
| `0x07`–`0x14` | `0x17`/`0x83`/`0x10` | Unknown; looks like a table (fan curve?) |
| `0x15`+ | NAK | Not present |

Notes:
- **Duty 0 stops the fan completely.** This controller's floor is 30% on purpose.
- Writes to `0x04` while a driver-less address: plain `i2cset -y` works; do **not** use `-f`.
- Warning: `0x69` on *other* buses of this board is a different (or no) device. The installer probes before touching anything.

## What this does

`fan-control.sh` runs as a systemd service on the Cube. Every 5 seconds it reads the CPU package temperature (`x86_pkg_temp`) and sets the duty:

| CPU temp | Duty |
|----------|------|
| < 50 °C | 30 % (inaudible) |
| 50–59 °C | 40 % |
| 60–69 °C | 55 % |
| 70–79 °C | 75 % |
| 80–89 °C | 90 % |
| ≥ 90 °C | 100 % |

Ramp-up requires the higher band to be **sustained**: 3 consecutive samples (15 s) normally, 2 samples (10 s) at or above 70 °C, and single-sample only at or above 90 °C. This matters because ZimaOS background services (`icewhale-files` in particular) produce ~2 s CPU bursts that spike the package temperature to 70–83 °C every minute or so at idle; reacting to single samples makes the fan audibly "boost" for no thermal reason. Heat only matters if it is sustained, and the CPU's own throttling at 100 °C is the hardware backstop. Ramp-down has 3 °C of hysteresis. The duty is re-asserted every 60 s in case the MCU resets.

**Failsafe:** if the service exits for any reason, an EXIT trap returns the MCU to factory default. The worst failure mode is a *loud* fan, never a *stopped* one. systemd (`Restart=always`) then brings the quiet mode back.

Validated under load: a full 12-thread burn took the CPU to 86 °C, the loop ramped to 90 % duty, airflow brought it down to ~75 °C, and everything returned to a quiet 30 % after the load stopped.

## Install

On the ZimaCube (i2c-tools ships with ZimaOS):

```sh
git clone https://github.com/viktorkav/zimacube-fan-control.git
cd zimacube-fan-control
sudo ./install.sh
```

The installer probes the MCU (read-only) before installing and aborts if `0x69` doesn't answer on bus 0.

**ZimaOS updates may remove the service** (the rootfs is a RAUC A/B image; `/etc` and `/opt` persist across reboots but not necessarily across updates). If the fan ever goes back to loud-by-default after an update, re-run the installer.

## Uninstall

```sh
sudo systemctl disable --now zima-fan.service   # EXIT trap restores factory default
sudo rm -rf /opt/zima-fan /etc/systemd/system/zima-fan.service
sudo systemctl daemon-reload
```

## Credits

- **SabiTech** on the IceWhale Discord pointed me to the MCU at `0x69` and the mailbox command format — that was the key that unlocked the whole thing.
- Register map, mode semantics, curve/hysteresis loop, failsafe design and load validation by [ViktorKav](https://github.com/viktorkav).

## Disclaimer

This writes to an undocumented device on your SMBus. It works on my ZimaCube 2 Pro with the exact versions listed above. Other boards, revisions or firmware may differ; the installer's probe reduces the risk but does not eliminate it. Use at your own risk.
