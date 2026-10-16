#!/bin/sh
# Convert the Memory Stick's Linux partition from ext2 (BusyBox mke2fs) to ext4: journal,
# extents, directory index, uninit_bg. Run from the BusyBox system (other/noroot on the card),
# with the partition not mounted. BusyBox has no full tune2fs, so Debian's tune2fs and e2fsck
# and their libraries are copied from the partition into RAM and run from there.
set -e
DEV=/dev/mspblk0p2
E2=/tmp/e2

grep -q "^$DEV " /proc/mounts && umount $DEV
mkdir -p /newroot $E2
mount -o ro $DEV /newroot
L=/newroot/usr/lib/arm-linux-gnueabi
for f in ld-linux.so.3 libc.so.6 libext2fs.so.2 libcom_err.so.2 libblkid.so.1 libuuid.so.1 \
	 libe2p.so.2; do
	cp -L $L/$f $E2/
done
cp -L /newroot/usr/sbin/tune2fs /newroot/usr/sbin/e2fsck $E2/
umount /newroot

run() { $E2/ld-linux.so.3 --library-path $E2 "$@"; }

run $E2/e2fsck -fy $DEV || [ $? -le 1 ]   # 1 = errors corrected
run $E2/tune2fs -j -O extent,huge_file,dir_index,dir_nlink,uninit_bg $DEV
# The new features need a full check: builds the directory indexes, sets up group checksums.
run $E2/e2fsck -fyD $DEV || [ $? -le 1 ]
run $E2/tune2fs -l $DEV | grep -E "features|Inode size|Block count"
echo "Done: $DEV is ext4. Remove other/noroot from the card and reboot."
