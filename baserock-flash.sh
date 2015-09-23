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
    sleep 1
    losetup -D
    rm -rf tmp || true
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

check_partitioning()
{
    # Check to see if the Baserock image is already partitioned
    if [ "`fdisk -l $1 | egrep \"$1[0-9]+\" 2> /dev/null | wc -l`" -eq "0"  ]; then
        echo 'Using unpartitioned image'
        partitioned_image=0
    else
        echo 'Using partitioned image'
        partitioned_image=1
    fi
}

get_sector_size()
{
    echo "$(fdisk -l $1 | grep "Sector size" | awk '{print $4}' 2> /dev/null)"
    return 0
}

mount_ro()
{
    loopdev=$(losetup --show --read-only -f -P -o "$1" "$2")
    mount "$loopdev" "$3"
}

mount_partition_containing()
{
    # Search for a partition containing a filename
    mkdir -p "$3"
    sector_size=$(get_sector_size "$2")
    for offset in $(fdisk -l "$2" | egrep "$2[0-9]+" | awk '{print $2}'); do
        if mount_ro "$(($offset * $sector_size))" "$2" "$3"; then
            testpath="$3/$1"
            if [ -f $testpath ] || [ -d $testpath ]; then
                return 0
            fi
            sleep 1
            umount "$3"
        fi
    done
    rm -rf "$3"
    echo "Can't find target '$1' in any partition in the image" 1>&2
    exit 1
}

mount_root_fs()
{
    # Search for a partition containing a Baserock rootfs
    mount_partition_containing 'systems/default/orig/baserock' "$1" "$2"
    return 0
}

mount_boot()
{
    # Identify the boot partition by UUID from fstab in the rootfs, and mount it
    sector_size=$(get_sector_size "$1")
    boot_uuid=$(cat tmp/fstab | grep /boot | awk '{print $1}' | sed 's/UUID=//')

    for offset in $(fdisk -l "$1" | egrep "$1[0-9]+" | awk '{print $2}'); do
        offset=$(($offset * $sector_size))
        part_uuid=$(blkid -p -O "$offset" -o value -s UUID "$1")
        if [ "$part_uuid" == "$boot_uuid" ]; then
            mkdir -p "$2"
            echo "Mounting /boot partition, filesystem UUID=$part_uuid"
            if [ "$3" == 'rw' ]; then
                mount -o loop,offset="$offset" "$1" "$2"
            else
                mount_ro "$offset" "$1" "$2"
            fi
            return 0
        fi
    done
    echo "ERROR: /boot partition not found."
    return 1
}

check_partitioning $baserock_image

source flashscripts/${device_type}-flash.sh

mount_baserock_image()
{
    mkdir -p tmp/brmount
    mkdir -p tmp/boot
    if [ "$partitioned_image" -eq "0" ]; then
        mount_ro 0 $1 tmp/brmount
        cp -a -r tmp/brmount/systems/factory/run/boot/* tmp/boot/
    else
        mkdir -p tmp/bootmnt
        mount_root_fs "$1" tmp/brmount
        cp 'tmp/brmount/systems/default/orig/etc/fstab' tmp
        mount_boot "$1" tmp/bootmnt
        cp -a -r tmp/bootmnt/* tmp/boot
        sync
        umount tmp/bootmnt
        rm -rf tmp/bootmnt
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
        sync
    else
        echo "Did not find pv, to see progress of this flash use:"
        echo "    kill -USR1 dd"
        echo "from another terminal"
        dd if=$1 of="$target" bs=8M
        sync
    fi
    return 0
}

copy_boot()
{
    echo "Copying boot files to boot partition"
    mkdir -p tmp/bootmount
    if [ "$partitioned_image" -eq "0" ]; then
        mount "/dev/${1}1" tmp/bootmount
    else
        mount_boot "/dev/$1" tmp/bootmount 'rw'
    fi
    cp -r tmp/boot/* tmp/bootmount
    sync
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

fs_device=`comm -3 tmp/devices.existing tmp/devices.new | sed -e 's/^[ \t]*//' | sed 's/loop[0-9]\+//g'`
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
fi
flash_br $baserock_image $1
copy_boot $1

echo "Now reboot the device and enjoy baserock!"
