#!/bin/sh
# Copyright (C) 2014  Codethink Limited
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

set -e
mkdir -p tmp/
baserock_image=$1
device_type=$2

partitioned_image=0

cleanup()
{
    umount tmp/* &>/dev/null || true
    rm -rf tmp/* || true
}
trap cleanup EXIT

if [ "$baserock_image" = "" ] || [ ! -f "$baserock_image" ]; then
    echo "Must specify a baserock image to flash!"
    exit 1
fi;

if [ "$device_type" = "" ]; then
    # default to jetson-tk1 for now
    device_type=jetson-tk1
fi;

if [ ! -f "flashscripts/${device_type}-flash.sh" ]; then
    echo "Sorry, we do not support such a board: $device_type"
    exit 1
fi;

# Check to see if the Baserock image is already partitioned
check_partitioning()
{
    mkdir tmp/testmnt
    if mount -t btrfs $baserock_image tmp/testmnt; then
        umount tmp/testmnt
        partitioned_image=0
    else
        partitioned_image=1
    fi
    rm tmp/testmnt
}

# Search for a partition containing a filename
find_partition_containing()
{
    mkdir tmp/testmnt
    ret=1
    for offset in $(fdisk -l $2 | egrep "$2[0-9]+" | awk '{print $2}'); do
        if mount -o loop,offset="$offset" -t btrfs $2 tmp/testmnt; then
            if [ -f "$1" ]; then
                echo "$offset"
                ret=0
            fi
            umount tmp/testmnt
        fi
    done
    rm tmp/testmnt
    if [ $ret == 1 ]; then
        echo "Can't find target '$1' in any partition in the image"
        exit 1
    fi
    return $ret
}

# Search for a partition containing a Baserock rootfs
find_root_fs()
{
    find_partition_containing 'tmp/test/systems/default/orig/baserock' $1
}

# Search for a partition containing boot files
find_boot()
{
    find_partition_containing 'u-boot.bin' $1
}

check_partitioning

source flashscripts/${device_type}-flash.sh

mount_baserock_image()
{
    mkdir -p tmp/brmount
    mkdir -p tmp/boot
    if [ "$partitioned_image" -eq "0"]; then
        mount -t btrfs $1 tmp/brmount
        cp -a -r tmp/brmount/systems/factory/run/boot/* tmp/boot/
    else
        mount -o loop,offset=$(find_root_fs $1) -t btrfs $1 tmp/brmount
        mount -o loop,offset=$(find_boot $1) -t btrfs $1 tmp/boot
    fi
    return 0
}

umount_baserock_image()
{
    umount tmp/brmount
    return 0
}

flash_br()
{
    if [ "$partitioned_image" -eq "1" ]; then
        target="/dev/${2}"
    else
        target="/dev/${2}2"
    fi
    echo "Flashing $1 to $target"
    if [ `command -v pv` ]; then
        pv -tpreb $1 | dd of="$target" bs=8M
    else
        echo "Did not find pv, to see progress of this flash use:"
        echo "    kill -USR1 dd"
        echo "from another terminal"
        dd if=$1 of="$target" bs=8M
    fi
    return 0
}

copy_boot()
{
    echo "Copying boot files to boot partition"
    mkdir -p tmp/bootmount
    mount /dev/${1}1 tmp/bootmount
    cp -r tmp/boot/* tmp/bootmount
    umount tmp/bootmount
    return 0
}

# get existing devices
cat /proc/partitions | tr -s ' ' | cut -d ' ' -f 5 > tmp/devices.existing

board_instructions

# setup the files needed on the boot partition
mount_baserock_image $baserock_image
board_setup_boot_folder
umount_baserock_image

# u-boot install
board_flash_uboot

# we're either using gadget mode, or there's an sd card, either way there
# should be a new device now

sleep 5

cat /proc/partitions | tr -s ' ' | cut -d ' ' -f 5 > tmp/devices.new

# partition

fs_device=`comm -3 tmp/devices.existing tmp/devices.new | sed -e 's/^[ \t]*//'`
echo $fs_device
set -- $fs_device

if [ "$1" == "" ]; then
    confirm=no
else
    echo "Found /dev/$1 as your device"
    echo "Please confirm this is the correct device [yes/no]"
    read confirm
fi;

if [ "$confirm" != "yes" ] && [ "$confirm" != "no" ]; then
    echo "Leaving install process"
    exit 1
fi;

if [ "$confirm" != "yes" ]; then
    echo "Failed to detect device"
    echo "Please enter the device (e.g sdc, not /dev/sdc) of your sdcard/board"
    read fs_device
    echo "flashing device now $fs_device"
    echo $fs_device
    if [ ! -b "/dev/${fs_device}" ]; then
        echo "Didn't find the device, exiting"
        exit 1
    fi;
fi;

# now loop through the above array
echo "Making sure device is unmounted"
for i in $fs_device
do
   echo "unmount $i"
   umount /dev/$i || true
done

set -- $fs_device
fs_device=$1

if [ "$partitioned_image" -eq "0" ]; then
    # partition device
    echo "Partitioning device /dev/$fs_device"
    echo "This can cause catastrophic data loss if /dev/$fs_device is not the intended target!"
    echo "Press enter to confirm, or Ctrl+C to quit (you have been warned!)"
    read confirm

    board_partition $1
    copy_boot $1
fi
flash_br $baserock_image $1

echo "Now reboot the device and enjoy baserock!"
