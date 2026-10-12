# Linux on the Sony Ericsson P1i

Kernel configuration, device tree and initramfs for running Linux on the Sony Ericsson
P1i (NXP PNX4008, ARM926EJ-S @ 208 MHz). Linux is started from Symbian by the
`linux_handover` project (handover LDD + bare-metal stub, built separately under wine).

## Layout

| Path | What |
|---|---|
| `p1i.config` | Kernel config fragment, applied with `KCONFIG_ALLCONFIG` on top of `allnoconfig` |
| `dts/pnx4008-p1i.dts` | Board device tree (the copy to edit; `build.sh` syncs it into `linux/`) |
| `busybox.config` | BusyBox 1.37.0 config: static, armel glibc, `-std=gnu17`, no `tc`/SHA HW accel |
| `rootfs/etc/` | `inittab` (shell on ttyS0) and `init.d/rcS` (mounts proc/sys/devtmpfs/tmpfs) |
| `initramfs.list` | Initramfs entries that need root to create (`/dev/console`) |
| `build.sh` | Builds BusyBox into `rootfs/`, then the kernel into `build/zImage-p1i` |
| `linux/` | Kernel tree, separate git repo: Linux 6.1.2 + branch `p1i` |

## Build

```sh
./build.sh
cp build/zImage-p1i /path/to/linux_handover/baremetal/
```

Then build `linux_handover` (`build-linux.sh`), which appends the kernel to the stub as
`p1i_linux.bin`. On the phone the payload goes to `D:\other\p1i_linux.bin`.

## Status

Boots to a BusyBox shell on UART6 (the removed IrDA module's pads, 115200 8N1) with the
console interrupt-driven, MSTIM as clocksource/clockevent, and `reboot` via the watchdog.
No clock driver yet (fixed-rate clocks; the stub sets up the UARTs), no storage, display
or input.
