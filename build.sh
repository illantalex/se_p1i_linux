#!/bin/sh
# build.sh -- build the Sony Ericsson P1i Linux image: build/zImage-p1i (zImage + DTB) with a
# static BusyBox initramfs built in. Copy the result to ../linux_handover/baremetal/ (or
# wherever the handover project lives) to make the phone payload p1i_linux.bin.
#
# Needs: arm-none-eabi-gcc (kernel), arm-linux-gnueabi-gcc (BusyBox and libgpiod, armel
# glibc). The kernel tree is linux/: if it is missing, Linux 6.1.2 is downloaded and the
# patches in patches/ are applied with git am (branch p1i). After committing kernel
# changes there, refresh the series with
#   rm patches/*.patch && git -C linux format-patch -o ../patches v6.1.2..p1i
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
JOBS=$(nproc)
BB_VER=1.37.0
BB_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
BB="$TOP/busybox-$BB_VER"
GPIOD_VER=2.2.5
GPIOD_SHA256=0df1bb2be89d9091a167b9f702f8f31d89863e8d84997aad09ee4aba12fe78c5
GPIOD="$TOP/libgpiod-$GPIOD_VER"
K_VER=6.1.2
K_SHA256=ee41f3c4f599b2f46f08aae428c9243db403e7292eb2c9f04ee34909b038d1ae
BB_MAKE="make -C $BB CROSS_COMPILE=arm-linux-gnueabi-"
K_MAKE="make -C $TOP/linux O=$TOP/build ARCH=arm CROSS_COMPILE=arm-none-eabi-"

echo "=== BusyBox $BB_VER"
cd "$TOP"
if [ ! -d "$BB" ]; then
	[ -f busybox-$BB_VER.tar.bz2 ] ||
		curl -fL -o busybox-$BB_VER.tar.bz2 https://busybox.net/downloads/busybox-$BB_VER.tar.bz2
	echo "$BB_SHA256  busybox-$BB_VER.tar.bz2" | sha256sum -c -
	tar xjf busybox-$BB_VER.tar.bz2
fi
# Copy only on change, so an unchanged config does not force a rebuild.
cmp -s busybox.config "$BB/.config" || cp busybox.config "$BB/.config"
$BB_MAKE oldconfig </dev/null >/dev/null
$BB_MAKE -j"$JOBS"
$BB_MAKE CONFIG_PREFIX="$TOP/rootfs" install >/dev/null
mkdir -p rootfs/dev rootfs/proc rootfs/sys rootfs/tmp rootfs/root
ln -sfn bin/busybox rootfs/init

echo "=== libgpiod $GPIOD_VER tools + own tools"
if [ ! -d "$GPIOD" ]; then
	[ -f libgpiod-$GPIOD_VER.tar.xz ] ||
		curl -fL -o libgpiod-$GPIOD_VER.tar.xz \
			https://mirrors.edge.kernel.org/pub/software/libs/libgpiod/libgpiod-$GPIOD_VER.tar.xz
	echo "$GPIOD_SHA256  libgpiod-$GPIOD_VER.tar.xz" | sha256sum -c -
	tar xJf libgpiod-$GPIOD_VER.tar.xz
	(cd "$GPIOD" && ./configure --host=arm-linux-gnueabi --enable-tools --enable-static \
		--disable-shared --disable-bindings-cxx --disable-bindings-python --prefix=/usr \
		>/dev/null)
fi
make -C "$GPIOD" -j"$JOBS" >/dev/null
# One static multi-call binary (gpiod-multi.c) instead of five: each tool's main() is
# renamed to <tool>_main, and they share one copy of glibc.
GPIOD_TOOLS="gpiodetect gpioinfo gpioget gpioset gpiomon"
OBJS=
for t in $GPIOD_TOOLS; do
	arm-linux-gnueabi-objcopy --redefine-sym main=${t}_main \
		"$GPIOD/tools/$t.o" "$GPIOD/tools/$t-multi.o"
	OBJS="$OBJS $GPIOD/tools/$t-multi.o"
done
# Own small tools (memdump.c: /dev/mem dumper, evdump.c: input event viewer, p1ikbd.c:
# keypad-to-console daemon, dsptool.c: audio DSP experiments) share the binary the same way.
OWN_TOOLS="memdump evdump p1ikbd dsptool"
for t in $OWN_TOOLS; do
	arm-linux-gnueabi-gcc -O2 -Wall -c -Dmain=${t}_main -o "$GPIOD/tools/$t-multi.o" $t.c
	OBJS="$OBJS $GPIOD/tools/$t-multi.o"
done
arm-linux-gnueabi-gcc -O2 -static -s -o "$GPIOD/tools/gpiod-multi" gpiod-multi.c $OBJS \
	"$GPIOD/tools/tools-common.o" "$GPIOD/lib/.libs/libgpiod.a"
mkdir -p rootfs/usr/bin
cp "$GPIOD/tools/gpiod-multi" rootfs/usr/bin/gpiod-multi
for t in $GPIOD_TOOLS $OWN_TOOLS; do
	ln -sfn gpiod-multi rootfs/usr/bin/$t
done

# Proprietary firmware is never committed: if a local firmware/ directory exists (e.g. the
# DSP images from the phone's Z:\private\10200B19), it goes into the initramfs as /lib/firmware.
rm -rf rootfs/lib/firmware
if [ -d firmware ]; then
	mkdir -p rootfs/lib/firmware
	cp -r firmware/. rootfs/lib/firmware/
	echo "=== Firmware: $(cd firmware && find . -type f | wc -l) file(s) from firmware/ into /lib/firmware"
fi

echo "=== Kernel"
cd "$TOP"
if [ ! -d linux ]; then
	echo "linux/ missing: fetching Linux $K_VER and applying patches/"
	[ -f linux-$K_VER.tar.xz ] ||
		curl -fL -o linux-$K_VER.tar.xz \
			https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$K_VER.tar.xz
	echo "$K_SHA256  linux-$K_VER.tar.xz" | sha256sum -c -
	tar xJf linux-$K_VER.tar.xz
	mv linux-$K_VER linux
	(cd linux && git init -q && git add -A &&
	 git -c user.name=build -c user.email=build@localhost commit -q -m "Linux $K_VER" &&
	 git tag v$K_VER && git checkout -q -b p1i &&
	 git -c user.name=build -c user.email=build@localhost am -q ../patches/*.patch)
fi
# dts/ is the copy that gets edited; keep the kernel tree's copy (committed on p1i) in step.
if ! cmp -s dts/pnx4008-p1i.dts linux/arch/arm/boot/dts/pnx4008-p1i.dts; then
	cp dts/pnx4008-p1i.dts linux/arch/arm/boot/dts/pnx4008-p1i.dts
	echo "NOTE: copied dts/pnx4008-p1i.dts into linux/ -- commit it there too"
fi
# Everything not in p1i.config is off; CONFIG_INITRAMFS_SOURCE in it is relative to build/.
$K_MAKE KCONFIG_ALLCONFIG="$TOP/p1i.config" allnoconfig >/dev/null
$K_MAKE -j"$JOBS" zImage dtbs
cat build/arch/arm/boot/zImage build/arch/arm/boot/dts/pnx4008-p1i.dtb > build/zImage-p1i

echo "=== Done: $TOP/build/zImage-p1i ($(stat -c %s build/zImage-p1i) bytes)"
