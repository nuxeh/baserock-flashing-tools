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

board_instructions()
{
    echo "Please put your Jetson into recovery mode now"
    echo "Hit enter when this is done, and the board is attached to the flashing host"
    read confirm
    return 0
}

board_setup_boot_folder()
{
    factory="/systems/factory/"
    boot_dir="tmp/boot"
    mount_dir="tmp/brmount"
    current_dir=`pwd`
    mkdir -p "$boot_dir/extlinux/"
    cp "$mount_dir/extlinux.conf" "$boot_dir/extlinux/"
    sed -i "s/mmcblk0p1/mmcblk0p2/" "$boot_dir/extlinux/extlinux.conf"
    mkdir -p "$boot_dir/systems/factory"
    cp "$mount_dir/systems/factory/kernel" "$boot_dir/systems/factory/"
    cp "$mount_dir/systems/factory/dtb" "$boot_dir/systems/factory/"
    cd "$boot_dir/systems/"
    ln -s factory default
    cd "$current_dir"
    rm "$boot_dir/kernel" &> /dev/null || true
    rm "$boot_dir/dtb" &> /dev/null || true
    return 0
}

board_flash_uboot()
{
    echo "flash u-boot"
    : ${TEGRA_TOOLS_DIR='/usr/share/baserock-flashing-tools/jetson-tk1/'}

    if [ -d $TEGRA_TOOLS_DIR/bin ] ; then
        export PATH="$TEGRA_TOOLS_DIR/bin:$PATH"
        echo $PATH
    fi

    if [ -d $TEGRA_TOOLS_DIR/_out_tools ] ; then
        export PATH="$TEGRA_TOOLS_DIR/_out_tools:$PATH"
        echo $PATH
    fi

    tegra_cbootimage_app=$(which cbootimage) || true
    if [ ! -x "$tegra_cbootimage_app" ] ; then
        echo "Couldn't find cbootimage"
        echo "Please ensure cbootimage,dtc,ftdput and tegrarcm are in your $PATH"
        exit 1
    fi

    failed=0
    tegra_uboot_flasher=$TEGRA_TOOLS_DIR/tegra-uboot-flasher-scripts/tegra-uboot-flasher
    if [ ! -f "${tegra_uboot_flasher}" ]; then
        echo "Failed to find tegra-uboot-flasher"
        failed=1
    fi

    tegra_cbootimage_cfg=$TEGRA_TOOLS_DIR/cbootimage-configs/
    if [ ! -d "${tegra_cbootimage_cfg}" ]; then
        echo "Failed to find cbootimage-configs"
        failed=1
    fi

    if [ "$failed" -eq "1" ]; then
        echo "Please set TEGRA_TOOLS_DIR to the folder containing:"
        echo "    * tegra-uboot-flasher-scripts/"
        echo "    * cbootimage-configs/"
        exit 1
    fi
 
    tegra_uboot_flasher_dir=`echo $tegra_uboot_flasher | sed 's|\(.*\)/.*|\1|'`

    mkdir -p tmp/jetson-workdir/jetson-tk1
    cp -r "$tegra_uboot_flasher_dir/configs" tmp/jetson-workdir/ 
    work_dir="tmp/jetson-workdir"
    cp -r "$tegra_cbootimage_cfg/tegra124/nvidia/jetson-tk1/"* $work_dir/jetson-tk1/

    # move files needed for flashing, we don't need these on the boot partition
    mv tmp/boot/u-boot.bin $work_dir/jetson-tk1/u-boot.bin
    mv tmp/boot/u-boot/* $work_dir/jetson-tk1/
    rm -rf tmp/boot/u-boot/
    current_dir=`pwd`
    cd $work_dir/jetson-tk1
    $tegra_cbootimage_cfg/build/gen-image-deps.sh jetson-tk1-emmc.img.cfg jetson-tk1-emmc.img .jetson-tk1-emmc.img.d
    $tegra_cbootimage_app -gbct -t124 PM375_Hynix_2GB_H5TC4G63AFR_RDA_924MHz.bct.cfg PM375_Hynix_2GB_H5TC4G63AFR_RDA_924MHz.bct
    $tegra_cbootimage_app -t124 jetson-tk1-emmc.img.cfg jetson-tk1-emmc.img
    cd $current_dir
    $tegra_uboot_flasher --force-no-out-dir --data-dir $work_dir flash --post-flash-cmd 'ums 0 mmc 0' jetson-tk1
    return 0
}

board_partition()
{
    # You may implement disk paritioning here, if the Baserock image is not
    # already partitioned using the rawdisk.write extension. If this script
    # detects that the image is already partitioned, this function will not
    # be called

    fdisk /dev/$1 <<EOF
g

n
1

+1G
n
2


w
EOF

    echo "Format /dev/${1}1 as ext4"
    mkfs -t ext4 /dev/${1}1
    return 0
}
