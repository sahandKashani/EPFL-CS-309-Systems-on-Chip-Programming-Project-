#!/bin/bash -x

# make sure to be in the same directory as this script
script_dir_abs=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
cd "${script_dir_abs}"

# constants ####################################################################
sdcard_dev="$(readlink -m "${1}")"

quartus_dir="$(readlink -m "hw/quartus")"
quartus_project_name="$(basename "$(find "${quartus_dir}" -name "*.qpf")" .qpf)"
quartus_sof_file="$(readlink -m "${quartus_dir}/output_files/${quartus_project_name}.sof")"

preloader_dir="$(readlink -m "sw/hps/preloader")"
preloader_settings_dir="$(readlink -m "${quartus_dir}/hps_isw_handoff/soc_system_hps_0")"
preloader_settings_file="$(readlink -m "${preloader_dir}/settings.bsp")"
preloader_source_tgz_file="$(readlink -m "${SOCEDS_DEST_ROOT}/host_tools/altera/preloader/uboot-socfpga.tar.gz")"
preloader_bin_file="${preloader_dir}/preloader-mkpimage.bin"

uboot_src_dir="$(readlink -m "sw/hps/u-boot")"
uboot_src_git_repo="git://git.denx.de/u-boot.git"
uboot_script_file="$(readlink -m "${uboot_src_dir}/u-boot.script")"
uboot_img_file="$(readlink -m "${uboot_src_dir}/u-boot.img")"

linux_dir="$(readlink -m "sw/hps/linux")"
linux_src_git_repo="git@github.com:torvalds/linux.git"
linux_src_dir="$(readlink -m "${linux_dir}/source")"
linux_kernel_mem_arg="768M"
linux_zImage_file="$(readlink -m "${linux_src_dir}/arch/arm/boot/zImage")"
linux_dtb_file="$(readlink -m "${linux_src_dir}/arch/arm/boot/dts/socfpga_cyclone5_de0_sockit.dtb")"

rootfs_dir="${linux_dir}/rootfs"
rootfs_chroot_dir="$(readlink -m ${rootfs_dir}/ubuntu-core-rootfs)"
rootfs_src_tgz_link="http://cdimage.ubuntu.com/ubuntu-core/releases/14.04/release/ubuntu-core-14.04.4-core-armhf.tar.gz"
rootfs_src_tgz_file="$(readlink -m "${rootfs_dir}/ubuntu-core-14.04.4-core-armhf.tar.gz")"
rootfs_config_script_file="${rootfs_dir}/rootfs_config.sh"

sdcard_fat32_dir="$(readlink -m "sdcard/fat32")"
sdcard_fat32_rbf_file="$(readlink -m "${sdcard_fat32_dir}/socfpga.rbf")"
sdcard_fat32_uboot_scr_file="$(readlink -m "${sdcard_fat32_dir}/u-boot.scr")"
sdcard_fat32_zImage_file="$(readlink -m "${sdcard_fat32_dir}/zImage")"
sdcard_fat32_dtb_file="$(readlink -m "${sdcard_fat32_dir}/socfpga.dtb")"

sdcard_ext3_rootfs_tgz_file="$(readlink -m "sdcard/ext3_rootfs.tar.gz")"

sdcard_a2_dir="$(readlink -m "sdcard/a2")"
sdcard_a2_preloader_bin_file="$(readlink -m "${sdcard_a2_dir}/$(basename "${preloader_bin_file}")")"
sdcard_a2_uboot_img_file="$(readlink -m "${sdcard_a2_dir}/$(basename "${uboot_img_file}")")"

sdcard_dev_fat32="${sdcard_dev}1"
sdcard_dev_ext3="${sdcard_dev}2"
sdcard_dev_a2="${sdcard_dev}3"
sdcard_dev_fat32_mount_point="/tmp/${$}-fat32" # prepend PID for uniqueness
sdcard_dev_ext3_mount_point="/tmp/${$}-ext3" # prepend PID for uniqueness

# usage() ######################################################################
usage() {
    cat <<EOF
===================================================================
usage: compile.sh [sdcard_device]

positional arguments:
    sdcard_device    path to sdcard device file    [ex: "/dev/sdb"]
===================================================================
EOF
}

# echoerr() ####################################################################
echoerr() {
    cat <<< "${@}" 1>&2;
}

# compile_quartus_project() ####################################################
compile_quartus_project() {
    pushd "${quartus_dir}"

    rm -rf "c5_pin_model_dump.txt" \
           "db/" \
           "hps_isw_handoff/" \
           "hps_sdram_p0_all_pins.txt" \
           "incremental_db/" \
           "output_files" \
           "soc_system.sopcinfo" \
           "${sdcard_fat32_rbf_file}"

    # Analysis and synthesis
    quartus_map "${quartus_project_name}"

    # Execute HPS DDR3 pin assignment TCL script
    # it is normal for the following script to report an error, but it was
    # sucessfully executed
    ddr3_pin_assignment_script="$(find . -name "hps_sdram_p0_pin_assignments.tcl")"
    quartus_sta -t "${ddr3_pin_assignment_script}" "${quartus_project_name}"

    # Fitter
    quartus_fit "${quartus_project_name}"

    # Assembler
    quartus_asm "${quartus_project_name}"

    popd

    # convert .sof to .rbf in associated sdcard directory
    quartus_cpf -c "${quartus_sof_file}" "${sdcard_fat32_rbf_file}"
}

# compile_preloader() ##########################################################
compile_preloader() {
    rm -rf "${preloader_dir}" \
           "${sdcard_a2_preloader_bin_file}"

    mkdir -p "${preloader_dir}"

    # create bsp settings file
    bsp-create-settings \
    --bsp-dir "${preloader_dir}" \
    --preloader-settings-dir "${preloader_settings_dir}" \
    --settings "${preloader_settings_file}" \
    --type spl \
    --set spl.CROSS_COMPILE "arm-altera-eabi-" \
    --set spl.PRELOADER_TGZ "${preloader_source_tgz_file}" \
    --set spl.boot.BOOTROM_HANDSHAKE_CFGIO "1" \
    --set spl.boot.BOOT_FROM_NAND "0" \
    --set spl.boot.BOOT_FROM_QSPI "0" \
    --set spl.boot.BOOT_FROM_RAM "0" \
    --set spl.boot.BOOT_FROM_SDMMC "1" \
    --set spl.boot.CHECKSUM_NEXT_IMAGE "1" \
    --set spl.boot.EXE_ON_FPGA "0" \
    --set spl.boot.FAT_BOOT_PARTITION "1" \
    --set spl.boot.FAT_LOAD_PAYLOAD_NAME "$(basename "${uboot_img_file}")" \
    --set spl.boot.FAT_SUPPORT "0" \
    --set spl.boot.FPGA_DATA_BASE "0xffff0000" \
    --set spl.boot.FPGA_DATA_MAX_SIZE "0x10000" \
    --set spl.boot.FPGA_MAX_SIZE "0x10000" \
    --set spl.boot.NAND_NEXT_BOOT_IMAGE "0xc0000" \
    --set spl.boot.QSPI_NEXT_BOOT_IMAGE "0x60000" \
    --set spl.boot.RAMBOOT_PLLRESET "1" \
    --set spl.boot.SDMMC_NEXT_BOOT_IMAGE "0x40000" \
    --set spl.boot.SDRAM_SCRUBBING "0" \
    --set spl.boot.SDRAM_SCRUB_BOOT_REGION_END "0x2000000" \
    --set spl.boot.SDRAM_SCRUB_BOOT_REGION_START "0x1000000" \
    --set spl.boot.SDRAM_SCRUB_REMAIN_REGION "1" \
    --set spl.boot.STATE_REG_ENABLE "1" \
    --set spl.boot.WARMRST_SKIP_CFGIO "1" \
    --set spl.boot.WATCHDOG_ENABLE "1" \
    --set spl.debug.DEBUG_MEMORY_ADDR "0xfffffd00" \
    --set spl.debug.DEBUG_MEMORY_SIZE "0x200" \
    --set spl.debug.DEBUG_MEMORY_WRITE "0" \
    --set spl.debug.HARDWARE_DIAGNOSTIC "0" \
    --set spl.debug.SEMIHOSTING "0" \
    --set spl.debug.SKIP_SDRAM "0" \
    --set spl.performance.SERIAL_SUPPORT "1" \
    --set spl.reset_assert.DMA "0" \
    --set spl.reset_assert.GPIO0 "0" \
    --set spl.reset_assert.GPIO1 "0" \
    --set spl.reset_assert.GPIO2 "0" \
    --set spl.reset_assert.L4WD1 "0" \
    --set spl.reset_assert.OSC1TIMER1 "0" \
    --set spl.reset_assert.SDR "0" \
    --set spl.reset_assert.SPTIMER0 "0" \
    --set spl.reset_assert.SPTIMER1 "0" \
    --set spl.warm_reset_handshake.ETR "1" \
    --set spl.warm_reset_handshake.FPGA "1" \
    --set spl.warm_reset_handshake.SDRAM "0"

    # generate bsp
    bsp-generate-files \
    --bsp-dir "${preloader_dir}" \
    --settings "${preloader_settings_file}"

    # compile preloader
    make -j4 -C "${preloader_dir}"

    # copy artifacts to associated sdcard directory
    cp "${preloader_bin_file}" "${sdcard_a2_preloader_bin_file}"
}

# compile_uboot ################################################################
compile_uboot() {
    rm -rf "${sdcard_fat32_uboot_scr_file}" \
           "${sdcard_a2_uboot_img_file}"

    # if uboot source tree doesn't exist, then download it
    if [ ! -d "${uboot_src_dir}" ]; then
        git clone "${uboot_src_git_repo}" "${uboot_src_dir}"
    fi

    # use cross compiler instead of standard x86 version of gcc
    export CROSS_COMPILE=arm-linux-gnueabihf-

    # clean up source tree
    make -C "${uboot_src_dir}" distclean

    # create uboot config for socfpga_cyclone5 architecture
    make -C "${uboot_src_dir}" socfpga_cyclone5_config

    # compile uboot
    make -j4 -C "${uboot_src_dir}"

    # create uboot script
    cat <<EOF > "${uboot_script_file}"
echo --- Programming FPGA ---

# Load rbf from FAT partition into memory
fatload mmc 0:1 \$fpgadata $(basename ${sdcard_fat32_rbf_file});

# Program FPGA
fpga load 0 \$fpgadata \$filesize;

# enable the FPGA 2 HPS and HPS 2 FPGA bridges
run bridge_enable_handoff;

echo --- Setting Env variables ---

# Set the devicetree image to be used
setenv fdtimage $(basename ${sdcard_fat32_dtb_file});

# Set the kernel image to be used
setenv bootimage $(basename ${sdcard_fat32_zImage_file});

setenv mmcboot 'setenv bootargs mem=${linux_kernel_mem_arg} console=ttyS0,115200 root=\${mmcroot} rw rootwait; bootz \${loadaddr} - \${fdtaddr}';

echo --- Booting Linux ---

# mmcload & mmcboot are scripts included in the default socfpga uboot environment
# it loads the devicetree image and kernel to memory
run mmcload;

# mmcboot sets the bootargs and boots the kernel with the dtb specified above
run mmcboot;
EOF

    # compile uboot script to binary form
    mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n "${quartus_project_name}" -d "${uboot_script_file}" "${sdcard_fat32_uboot_scr_file}"

    # copy artifacts to associated sdcard directory
    cp "${uboot_img_file}" "${sdcard_a2_uboot_img_file}"
}

# compile_linux() ##############################################################
compile_linux() {
    # if linux source tree doesn't exist, then download it
    if [ ! -d "${linux_src_dir}" ]; then
        git clone "${linux_src_git_repo}" "${linux_src_dir}"
    fi

    # compile for the ARM architecture
    export ARCH=arm

    # use cross compiler instead of standard x86 version of gcc
    export CROSS_COMPILE=arm-linux-gnueabihf-

    # clean up source tree
    make -C "${linux_src_dir}" distclean

    # checkout the following commit (tested and working)
    # commit 9735a22799b9214d17d3c231fe377fc852f042e9
    # Author: Linus Torvalds <torvalds@linux-foundation.org>
    # Date:   Sun Apr 3 09:09:40 2016 -0500
    #
    #     Linux 4.6-rc2
    git checkout 9735a22799b9214d17d3c231fe377fc852f042e9

    # create kernel config for socfpga architecture
    make -C "${linux_src_dir}" socfpga_defconfig

    # compile zImage
    make -j4 -C "${linux_src_dir}" zImage

    # compile device tree
    make -j4 -C "${linux_src_dir}" socfpga_cyclone5_de0_sockit.dtb

    # copy artifacts to associated sdcard directory
    cp "${linux_zImage_file}" "${sdcard_fat32_zImage_file}"
    cp "${linux_dtb_file}" "${sdcard_fat32_dtb_file}"
}

# create_rootfs() ##############################################################
create_rootfs() {
    if [ ! -f "${rootfs_src_tgz_file}" ]; then
        wget "${rootfs_src_tgz_link}" -O "${rootfs_src_tgz_file}"
    fi

    sudo rm -rf "${rootfs_chroot_dir}" \
                "${sdcard_ext3_rootfs_tgz_file}"

    mkdir -p "${rootfs_chroot_dir}"

    # extract ubuntu core rootfs
    pushd "${rootfs_chroot_dir}"
    sudo tar -xzpf "${rootfs_src_tgz_file}"
    popd

    # mount directories needed for chroot environment to work
    sudo mount -o bind "/dev" "${rootfs_chroot_dir}/dev"
    sudo mount -t sysfs "/sys" "${rootfs_chroot_dir}/sys"
    sudo mount -t proc "/proc" "${rootfs_chroot_dir}/proc"

    # chroot environment needs to know what is mounted, so we copy over
    # /proc/mounts from the host for this temporarily
    sudo cp "/proc/mounts" "${rootfs_chroot_dir}/etc/mtab"

    # chroot environment needs network connectivity, so we copy /etc/resolv.conf
    # so DNS name resolution can occur
    sudo cp "/etc/resolv.conf" "${rootfs_chroot_dir}/etc/resolv.conf"

    # the ubuntu core image is for armhf, not x86, so we need qemu to actually
    # emulate the chroot (x86 cannot run bash executable included in the rootfs,
    # since it is for armhf)
    # dependencies : sudo apt-get install qemu-user-static
    sudo cp "/usr/bin/qemu-arm-static" "${rootfs_chroot_dir}/usr/bin/"

    # copy chroot configuration script to chroot directory
    sudo cp "${rootfs_config_script_file}" "${rootfs_chroot_dir}"

    # perform chroot and configure rootfs through script
    sudo chroot "${rootfs_chroot_dir}" ./"$(basename "${rootfs_config_script_file}")"

    # remove chroot configuration script to chroot directory
    sudo rm "${rootfs_chroot_dir}/$(basename "${rootfs_config_script_file}")"

    # unmount host directories temporarily used for chroot
    sudo umount "${rootfs_chroot_dir}/dev"
    sudo umount "${rootfs_chroot_dir}/sys"
    sudo umount "${rootfs_chroot_dir}/proc"

    # create archive of updated rootfs
    pushd "${rootfs_chroot_dir}"
    sudo tar -czpf "${sdcard_ext3_rootfs_tgz_file}" .
    popd
}

# partition_sdcard() ###########################################################
partition_sdcard() {
    # manually partitioning the sdcard
        # sudo fdisk /dev/sdx
            # use the following commands
            # n p 3 <default> 4095  t 3 a2 (2048 is default first sector)
            # n p 1 <default> +32M  t 1  b (4096 is default first sector)
            # n p 2 <default> +512M t 2 83 (69632 is default first sector)
            # w
        # result
            # Device     Boot Start     End Sectors  Size Id Type
            # /dev/sdb1        4096   69631   65536   32M  b W95 FAT32
            # /dev/sdb2       69632 1118207 1048576  512M 83 Linux
            # /dev/sdb3        2048    4095    2048    1M a2 unknown

    # automatically partitioning the sdcard
    # if scard does not have suitable partitions, then partition the device
    fdisk_output="$(sudo fdisk -l "${sdcard_dev}")"
    if [ "$(echo "${fdisk_output}" | grep -i -P "${sdcard_dev_fat32}.+b\s+W95 FAT32.*" | wc -l)" -eq 0 ] ||
       [ "$(echo "${fdisk_output}" | grep -i -P "${sdcard_dev_ext3}.+83\s+Linux.*" | wc -l)" -eq 0 ] ||
       [ "$(echo "${fdisk_output}" | grep -i -P "${sdcard_dev_a2}.+a2\s+Unknown.*" | wc -l)" -eq 0 ]; then
       cat <<EOF
Did not find required device ids on device ${sdcard_dev}:
    Required:    Device    Id       System
              ${sdcard_dev_fat32}     b    W95 FAT32
              ${sdcard_dev_ext3}    83        Linux
              ${sdcard_dev_a2}    a2      Unknown

Formatting sdcard ...
EOF
        # wipe partition table
        sudo dd if="/dev/zero" of="${sdcard_dev}" bs=512 count=1

        # create partitions
        # no need to specify the partition number for the first invocation of
        # the "t" command in fdisk, because there is only 1 partition at this
        # point
        echo -e "n\np\n3\n\n4095\nt\na2\nn\np\n1\n\n+32M\nt\n1\nb\nn\np\n2\n\n+512M\nt\n2\n83\nw\nq\n" | sudo fdisk "${sdcard_dev}"
    fi

    # create filesystems
    sudo mkfs.vfat "${sdcard_dev_fat32}"
    sudo mkfs.ext3 -F "${sdcard_dev_ext3}"
}

# write_sdcard() ###############################################################
write_sdcard() {
    # create mount point for sdcard in /tmp
    sudo mkdir -p "${sdcard_dev_fat32_mount_point}"
    sudo mkdir -p "${sdcard_dev_ext3_mount_point}"

    # mount sdcard partitions
    sudo mount "${sdcard_dev_fat32}" "${sdcard_dev_fat32_mount_point}"
    sudo mount "${sdcard_dev_ext3}" "${sdcard_dev_ext3_mount_point}"

    # preloader
    sudo dd if="${sdcard_a2_preloader_bin_file}" of="${sdcard_dev_a2}" bs=64K seek=0

    # uboot
    sudo dd if="${sdcard_a2_uboot_img_file}" of="${sdcard_dev_a2}" bs=64K seek=4

    # fpga .rbf, uboot .scr, linux zImage, linux .dtb
    sudo cp "${sdcard_fat32_dir}"/* "${sdcard_dev_fat32_mount_point}"

    # linux rootfs
    pushd "${sdcard_dev_ext3_mount_point}"
    sudo tar -xzf "${sdcard_ext3_rootfs_tgz_file}"
    popd

    # flush write buffers to target
    sudo sync

    # unmount sdcard partitions
    sudo umount "${sdcard_dev_fat32_mount_point}"
    sudo umount "${sdcard_dev_ext3_mount_point}"

    # delete mount points (were created in /tmp, so we can safely delete them
    sudo rm -rf "${sdcard_dev_fat32_mount_point}"
    sudo rm -rf "${sdcard_dev_ext3_mount_point}"
}

# Script execution #############################################################
if [ ! -d "${sdcard_a2_dir}" ]; then
    mkdir -p "${sdcard_a2_dir}"
fi

if [ ! -d "${sdcard_fat32_dir}" ]; then
    mkdir -p "${sdcard_fat32_dir}"
fi

compile_quartus_project
compile_preloader
compile_uboot
compile_linux
create_rootfs

if [ ! -b "${sdcard_dev}" ]; then
    usage
    echoerr "Error: could not find block device at \"${sdcard_dev}\""
    exit 1
elif [ ! "$(echo "${sdcard_dev}" | grep -P "/dev/sd\w\s*$")" ]; then
    usage
    echoerr "Error: must select a root drive (ex: /dev/sdb), not a subpartition (ex: /dev/sdb1)"
    exit 1
fi

partition_sdcard
write_sdcard

# Make sure MSEL = 000000
