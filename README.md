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
| Keypad | full QWERTZ keyboard, side keys, camera key, jog dial (Up/Down/Enter); shell on `tty1` typed through `p1ikbd` (below) |
| Backlights | display (PWM, 8 levels) and keypad; camera-flash LED as a torch (STCF03) |
| Core | interrupts (MIC/SIC1/SIC2), tickless MSTIM clocksource/clockevent, watchdog reboot |
| Buses | I2C1/I2C2, SoC GPIO, STMPE801 GPIO expander |
| Sound | ALSA playback, 8-48 kHz stereo, through the audio DSP on a stream Symbian started (headphones; see the handover's README) |
| FM radio | Si4703 tuner (`/dev/radio0`, `fm.sh`); audio after a handover with Symbian's FM radio playing, switchable with ALSA playback (below) |
| Touchscreen | `lpc32xx_ts` (`/dev/input/event1`) |
| RTC | the SoC RTC Symbian keeps running (UTC), set from NTP |
| Memory Stick | Memory Stick Micro slot read/write (`/dev/mspblk0p1`, FAT), 4-bit mode: reads 4.2 MB/s, writes ~1.6 MB/s; polling |
| Debian | trixie armel (sysvinit) from the Memory Stick's Linux partition, root shells on the display and serial console; ~12 MB RAM used at idle |
| USB | device mode on the Fast-Port connector: Ethernet gadget (CDC ECM, 12 Mbit/s), phone 192.168.7.2; `pc-usbnet.sh` on the PC shares its internet connection |
| Serial | 8250 console on UART6 (optional, needs soldering), UART5 |

Not yet: fast or interrupt-driven Memory Stick access, USB host, recording, camera, Wi-Fi, the GSM
baseband, and power management. The kernel does not initialise the display controller or the
panel itself, so it relies on starting from Symbian.

## Repository layout

| Path | What |
|---|---|
| `patches/` | The kernel changes, 51 patches on Linux 6.1.2 (drivers, Kconfig, device tree) |
| `p1i.config` | Kernel config fragment, applied with `KCONFIG_ALLCONFIG` on top of `allnoconfig` |
| `dts/pnx4008-p1i.dts` | Board device tree (the copy to edit; `build.sh` syncs it into `linux/`) |
| `busybox.config` | BusyBox 1.37.0: static, armel glibc |
| `rootfs/` | `inittab` (shells on `ttyS0` and `tty1`), `rcS`, `root/regdump.sh` |
| `initramfs.list` | Initramfs entries that need root to create (`/dev/console`) |
| `gpiod-multi.c`, `memdump.c`, `evdump.c`, `p1ikbd.c`, `dsptool.c` | One static multi-call binary: libgpiod tools, a `/dev/mem` dumper, an input-event viewer, the keypad daemon, audio DSP experiments |
| `initramfs-init.sh` | `/init`: switches to a Linux root on the Memory Stick (partition 2) if there is one, else runs the BusyBox system |
| `mkdebian.sh` | Builds a minimal Debian armel root (sysvinit) as a tarball, on the PC |
| `capture.sh` | Runs a command on the phone's serial shell and saves the output on the PC |
| `pc-usbnet.sh` | On the PC: addresses and NAT for the phone's USB network |
| `sendfile.sh` | Copies a file from the PC to the phone over the serial shell (base64, md5-checked) |
| `build.sh` | Builds everything into `build/zImage-p1i` |

Kernel patches, in short:

- new drivers: PNX4008 MSTIM timer, PNX4008 Memory Stick host, PNX4008 USB clocks, ST STCF03 flash LED, jog dial;
- `lpc32xx` irqchip, GPIO, PWM, key scanner, `i2c-pnx` and the PNX4008 watchdog enabled for
  ARMv5 multiplatform (the PNX4008 shares these blocks with the LPC32xx, but
  `ARCH_LPC32XX` itself does not boot here);
- fixes: `pwm-lpc32xx` NULL dereference at probe, `stmpe-i2c` without an interrupt, an
  interrupt storm from a stuck receive timeout on the 8250 UART (stalled the boot until a
  character arrived on the serial line);
- `arch/arm/boot/dts/pnx4008-p1i.dts`.

## Typing on the keypad

`p1ikbd` (started by `rcS`) turns the keypad into console input the way Symbian does:

| Key | Gives |
|---|---|
| Shift, Alt | apply to the next key; twice = Caps / Alt lock; a third press unlocks |
| Alt + key | the symbol or red digit printed on the key (`@ / : ? ( ) ' + - ! * #`, `1`-`9`, Space = `0`) |
| `.` | tapped again within a second, cycles through `` , ? ! _ \ \| ~ ` ^ & % $ " ; = < > [ ] { } # * @ / : ' ( ) + - `` |
| Back | Ctrl-C; Shift + Back = Ctrl-D |
| Shift, then Alt | Ctrl for the next key (e.g. Ctrl-Z) |
| `@` side key | Tab |
| arrows, jog dial | cursor keys; jog press = Enter |
| held key | repeats after 0.5 s, 30 per second (not Shift, Alt or the `.` multi-tap) |

It grabs the input devices, so stop it (`killall p1ikbd`) before using `evdump`.

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

Proprietary firmware is not part of this repository. If a local `firmware/` directory
exists, `build.sh` copies it into the initramfs as `/lib/firmware`; `dsptool` expects the
audio DSP images from the phone's `Z:\private\10200B19\` in `firmware/p1i-dsp/`
(`DspStartupCode.bin`, `DspStartupData.bin`).

To boot it, copy `build/zImage-p1i` into the handover project's `baremetal/`, run
`./build-linux.sh payload` there, and copy the resulting `p1i_linux.bin` to
`D:\other\p1i_linux.bin` on the phone (see the handover README).

When changing the kernel, commit in `linux/` and refresh the series:

```sh
rm patches/*.patch && git -C linux format-patch -o ../patches v6.1.2..p1i
```

## FM radio

The headset cable is the antenna and shares the Fast-Port with USB, so use the serial
console. The FM receiver's audio goes through the codec's line input and the audio DSP, and
only Symbian's FM radio sets that path up completely:

1. create `D:\other\nostream.txt` on the card (the handover then leaves the DSP as it is),
2. start the FM radio in Symbian with the headphones in, and hand over,
3. `/root/fm.sh on 99.3` (`seek`, `tune MHz`, `info`, `off`).

The ALSA control `Audio Source` switches the DSP's music path between the radio and ALSA
playback, as often as needed: `amixer -c 0 sset 'Audio Source' PCM` before playing, `FM` to
go back. Playback is refused while `FM` is selected. After a normal handover (no
`nostream.txt`), ALSA works, the radio stays silent and the control does not exist.

## Debian on the Memory Stick

The card can hold a Linux root on a second partition next to Symbian's FAT16. Symbian only
accepts a partition table whose first entry has the boot flag and keeps working with a second
partition behind it, but its "format memory card" rewrites the whole card (deleting the Linux
partition). Partitioning is done from Linux on the phone, since over USB Symbian only exports
the FAT partition.

1. On the PC: `sudo ./mkdebian.sh` (needs `mmdebstrap` and qemu ARM emulation) and copy the
   resulting `debian-armel-trixie.tar.gz` to the card.
2. On the phone, with the Linux partition at `/dev/mspblk0p2`:
   `mount /dev/mspblk0p2 /newroot && mkdir -p /tmp/card && mount /dev/mspblk0p1 /tmp/card &&
   tar -xzf /tmp/card/debian-armel-trixie.tar.gz -C /newroot && sync`
3. Reboot: `/init` finds `/sbin/init` on partition 2 and switches to Debian, with root shells
   on the display and the serial console. An empty file `other/noroot` on the card keeps the
   BusyBox system instead.

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
