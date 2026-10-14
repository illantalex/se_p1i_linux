# Linux for the Sony Ericsson P1i

Kernel patches, configuration, device tree and initramfs for running mainline **Linux 6.1** on
the **Sony Ericsson P1i** (UIQ 3 smartphone, NXP PNX4008, ARM926EJ-S at 208 MHz, 128 MB RAM).

Linux is started from a running Symbian by
[se_p1i_linux_handover](https://github.com/illantalex/se_p1i_linux_handover): a Symbian app
and kernel driver hand the machine to a bare-metal stub, which jumps to the kernel built
here. No reflashing; `reboot` returns to Symbian.

## What works

| | |
|---|---|
| Display | framebuffer console (240x320, 30x20 text), Symbian's display setup kept (`simple-framebuffer`) |
| Keypad | full QWERTZ keyboard, side keys, camera key, jog dial (Up/Down/Enter); shell on `tty1` |
| Backlights | display (PWM, 8 levels) and keypad; camera-flash LED as a torch (STCF03) |
| Core | interrupts (MIC/SIC1/SIC2), tickless MSTIM clocksource/clockevent, watchdog reboot |
| Buses | I2C1/I2C2, SoC GPIO, STMPE801 GPIO expander |
| FM radio | Si4703 reachable on I2C; plays if Symbian's FM app set up the audio path before the handover |
| Serial | 8250 console on UART6 (optional, needs soldering), UART5 |

Not yet: Memory Stick storage, USB, audio codec, camera, Wi-Fi, touchscreen, the GSM
baseband, and power management. The kernel does not initialise the display controller or the
panel itself, so it relies on starting from Symbian.

## Repository layout

| Path | What |
|---|---|
| `patches/` | The kernel changes, 17 patches on Linux 6.1.2 (drivers, Kconfig, device tree) |
| `p1i.config` | Kernel config fragment, applied with `KCONFIG_ALLCONFIG` on top of `allnoconfig` |
| `dts/pnx4008-p1i.dts` | Board device tree (the copy to edit; `build.sh` syncs it into `linux/`) |
| `busybox.config` | BusyBox 1.37.0: static, armel glibc |
| `rootfs/` | `inittab` (shells on `ttyS0` and `tty1`), `rcS`, `root/regdump.sh` |
| `initramfs.list` | Initramfs entries that need root to create (`/dev/console`) |
| `gpiod-multi.c`, `memdump.c`, `evdump.c` | One static multi-call binary: libgpiod tools, a `/dev/mem` dumper, an input-event viewer |
| `capture.sh` | Runs a command on the phone's serial shell and saves the output on the PC |
| `build.sh` | Builds everything into `build/zImage-p1i` |

Kernel patches, in short:

- new drivers: PNX4008 MSTIM timer, ST STCF03 flash LED, jog dial;
- `lpc32xx` irqchip, GPIO, PWM, key scanner, `i2c-pnx` and the PNX4008 watchdog enabled for
  ARMv5 multiplatform (the PNX4008 shares these blocks with the LPC32xx, but
  `ARCH_LPC32XX` itself does not boot here);
- fixes: `pwm-lpc32xx` NULL dereference at probe, `stmpe-i2c` without an interrupt;
- `arch/arm/boot/dts/pnx4008-p1i.dts`.

## Building

Needs `arm-none-eabi-gcc` (kernel), `arm-linux-gnueabi-gcc` (armel glibc, for BusyBox and
libgpiod), and the usual kernel build tools.

```sh
./build.sh
```

The first run downloads Linux 6.1.2, BusyBox 1.37.0 and libgpiod 2.2.5 (checksums verified),
unpacks the kernel into `linux/` as a git repository and applies `patches/` on a branch
`p1i`. The result is `build/zImage-p1i`: the zImage with the device tree appended and the
initramfs built in.

To boot it, copy `build/zImage-p1i` into the handover project's `baremetal/`, run
`./build-linux.sh payload` there, and copy the resulting `p1i_linux.bin` to
`D:\other\p1i_linux.bin` on the phone (see the handover README).

When changing the kernel, commit in `linux/` and refresh the series:

```sh
rm patches/*.patch && git -C linux format-patch -o ../patches v6.1.2..p1i
```

## Hardware notes

The device tree is commented with what was verified on the phone and how: interrupt lines,
clocks, GPIO assignments (from the service schematics), I2C devices, key matrix, display
memory layout. A few things that matter when porting further:

- Interrupt lines differ from the LPC32xx: UART5 = MIC 9, UART6 = MIC 10, I2C1/I2C2 =
  SIC1 19/18, MSTIM = MIC 27, key scanner = SIC1 22, GPIO_00 = SIC2 0.
- There is no clock driver: all clocks are fixed-rate (HCLK 104 MHz, peripheral clock 13
  MHz, 32.768 kHz). The handover stub turns on the UART and I2C clocks.
- glibc 2.43 armel uses the 32-bit time syscalls, so `CONFIG_COMPAT_32BIT_TIME` must stay on
  (without it `sleep` returns at once and BusyBox init spins).
- The display controller (DUM) refreshes the panel from Symbian's framebuffer at
  `0x81000000` by itself whenever it is written, so a reserved region plus
  `simple-framebuffer` is enough.

## Licence

GPL-2.0, see [LICENSE](LICENSE). The patches apply to the Linux kernel; BusyBox and libgpiod
are downloaded and built under their own licences.
