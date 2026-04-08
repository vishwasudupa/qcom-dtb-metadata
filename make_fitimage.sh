#!/bin/bash

# SPDX-License-Identifier: BSD-3-Clause-clear
#
# qcom fit image generator script
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#

###############################################################################
# make_fitimage.sh - FIT image packaging script for Qualcomm Linux development
#
# Usage:
#   ./make_fitimage.sh --metadata <metadata_dts> --its <fitimage_its> [--kobj <kernel_build_artifacts>] [--output <output_dir>]
#
# Options:
#   --metadata  Path to metadata DTS file (mandatory)
#   --its       Path to FIT image ITS file (mandatory)
#   --kobj      Path to kernel build artifacts directory (default: ../kobj)
#   --output    Output directory for generated FIT image (default: ../images)
#   --help      Show help message
#
# Description:
#   This script generates a FIT image using Qualcomm metadata and ITS files.
#   It compiles the metadata DTS to DTB, creates the FIT image using mkimage,
#   and packages the final image into a FAT image.
###############################################################################

set -e

# Default paths
KERNEL_BUILD_ARTIFACTS="kobj"
OUTPUT_DIR="../images"
METADATA_DTS_PATH="qcom-metadata.dts"
FIT_IMAGE_ITS_PATH="qcom-fitimage.its"

# FAT image generation constants
BOOTIMG_VOLUME_ID="BOOT"
BOOTIMG_EXTRA_SPACE="512"
MKFSVFAT_EXTRAOPTS="-S 512"

# Help message
function show_help() {
    cat <<EOF
Usage:
  ./make_fitimage.sh [OPTIONS]

Options:
  --metadata <path>  Path to metadata DTS file (default: $METADATA_DTS_PATH)
  --its <path>       Path to FIT image ITS file (default: $FIT_IMAGE_ITS_PATH)
  --kobj <path>      Path to kernel build artifacts directory (default: $KERNEL_BUILD_ARTIFACTS)
  --output <path>    Output directory for generated FIT image (default: $OUTPUT_DIR)
  --help             Show this help message and exit

Description:
  This script generates a FIT image using Qualcomm metadata and ITS files.
  It compiles the metadata DTS to DTB, creates the FIT image using mkimage,
  and packages the final image into a FAT image.

Note:
  You can obtain the metadata DTS and FIT image ITS files from:
  https://github.com/qualcomm-linux/qcom-dtb-metadata
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kobj) KERNEL_BUILD_ARTIFACTS="$2"; shift 2 ;;
        --metadata) METADATA_DTS_PATH="$2"; shift 2 ;;
        --its) FIT_IMAGE_ITS_PATH="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help ; exit 1 ;;
    esac
done

# Resolve paths
KERNEL_BUILD_ARTIFACTS="$(realpath "$KERNEL_BUILD_ARTIFACTS")"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
METADATA_DTS_PATH="$(realpath "$METADATA_DTS_PATH")"
FIT_IMAGE_ITS_PATH="$(realpath "$FIT_IMAGE_ITS_PATH")"

# Function to generate FAT image
function generate_fat_image() {
    local FATSOURCEDIR=$1
    local OUT_IMAGE=$2

    echo "Generating FAT image from ${FATSOURCEDIR}..."

    # Determine the sector count just for the data
    SECTORS=$(( $(du --apparent-size -ks "${FATSOURCEDIR}" | cut -f 1) * 2 ))

    # 32 bytes per dir entry
    DIR_BYTES=$(( $(find "${FATSOURCEDIR}" | tail -n +2 | wc -l) * 32 ))

    # 32 bytes for every end-of-directory dir entry
    DIR_BYTES=$(( DIR_BYTES + $(( $(find "${FATSOURCEDIR}" -type d | tail -n +2 | wc -l) * 32 )) ))

    # 4 bytes per FAT entry per sector of data
    FAT_BYTES=$(( SECTORS * 4 ))

    # 4 bytes per FAT entry per end-of-cluster list
    FAT_BYTES=$(( FAT_BYTES + $(( $(find "${FATSOURCEDIR}" -type d | tail -n +2 | wc -l) * 4 )) ))

    # Use a ceiling function to determine FS overhead in sectors
    DIR_SECTORS=$(( $(( DIR_BYTES + 511 )) / 512 ))

    # There are two FATs on the image
    FAT_SECTORS=$(( $(( $(( FAT_BYTES + 511 )) / 512 )) * 2 ))
    SECTORS=$(( SECTORS + $(( DIR_SECTORS + FAT_SECTORS )) ))

    # Determine the final size in blocks accounting for some padding
    BLOCKS=$(( $(( SECTORS / 2 )) + BOOTIMG_EXTRA_SPACE ))

    # mkfs.vfat will sometimes use FAT16 when it is not appropriate,
    # resulting in a boot failure. Use FAT32 for images larger
    # than 512MB, otherwise let mkfs.vfat decide.
    if [ "$(( BLOCKS / 1024 ))" -gt 512 ] ; then
        FATSIZE="-F 32"
        mkfs.vfat "${FATSIZE}" -n "${BOOTIMG_VOLUME_ID}" ${MKFSVFAT_EXTRAOPTS} -C "${OUT_IMAGE}" "${BLOCKS}"
    else
        mkfs.vfat -n "${BOOTIMG_VOLUME_ID}" ${MKFSVFAT_EXTRAOPTS} -C "${OUT_IMAGE}" "${BLOCKS}"
    fi

    MTOOLS_SKIP_CHECK=1 mcopy -i "${OUT_IMAGE}" -s "${FATSOURCEDIR}"/* ::/

    echo "FAT image created at ${OUT_IMAGE}"
}

# Function to create FIT image
function create_fit_image() {
    # Cleaning previous FIT image artifacts
    rm -f "${OUTPUT_DIR}/fit_dtb.bin"
    rm -rf "${OUTPUT_DIR}/fit_dir"
    rm -f "${KERNEL_BUILD_ARTIFACTS}/qcom-fitimage.its"
    rm -f "${KERNEL_BUILD_ARTIFACTS}/qcom-metadata.dtb"

    # Creating output directory
    mkdir -p "$OUTPUT_DIR/fit_dir"

    # Copying ITS file to kernel build artifacts path
    cp "$FIT_IMAGE_ITS_PATH" "$KERNEL_BUILD_ARTIFACTS/qcom-fitimage.its"

    #Compiling metadata DTS to DTB
    dtc -I dts -O dtb -o "${KERNEL_BUILD_ARTIFACTS}/qcom-metadata.dtb" "${METADATA_DTS_PATH}"

    echo "Generating FIT image..."
    mkimage -f "${KERNEL_BUILD_ARTIFACTS}/qcom-fitimage.its" "${OUTPUT_DIR}/fit_dir/qclinux_fit.img" -E -B 8

    echo "Packing final image into fit_dtb.bin..."
    generate_fat_image "${OUTPUT_DIR}/fit_dir" "${OUTPUT_DIR}/fit_dtb.bin"
}

echo "Starting FIT image creation..."
create_fit_image
echo "FIT image created at ${OUTPUT_DIR}/fit_dtb.bin"
