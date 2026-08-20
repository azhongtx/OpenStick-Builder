#!/bin/sh -e
# Populate prebuilt/<device>/ from the device flash package.
# Must run on Linux (native or WSL2) because rootfs.img is an ext4 filesystem
# image that has to be loop-mounted. Windows cannot do this directly.
#
# Usage:
#   FLASH_PKG=/path/to/刷机包 DEVICE=ufi103s sudo -E scripts/extract_prebuilt.sh
#
# FLASH_PKG : directory containing the original Debian flash package
#             (rootfs.img, aboot.bin, gpt_both0.bin, hyp.mbn, rpm.mbn,
#              sbl1.mbn, tz.mbn, ...)
# DEVICE     : device name used for the prebuilt directory (default ufi103s)

DEVICE=${DEVICE=ufi103s}
FLASH_PKG=${FLASH_PKG:?set FLASH_PKG to the flash package directory}
DEST="prebuilt/${DEVICE}"

[ -f "${FLASH_PKG}/rootfs.img" ] || { echo "ERROR: ${FLASH_PKG}/rootfs.img not found"; exit 1; }

mkdir -p "${DEST}/lib/modules" "${DEST}/lib/firmware"

TMP=$(mktemp -d)
LOOP=$(losetup -f)
cleanup() {
    umount "${TMP}" 2>/dev/null || true
    losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf "${TMP}"
}
trap cleanup EXIT

echo "Mounting ${FLASH_PKG}/rootfs.img ..."
losetup "${LOOP}" "${FLASH_PKG}/rootfs.img"
mount "${LOOP}" "${TMP}"

echo "Copying /lib/modules ..."
cp -a "${TMP}/lib/modules/." "${DEST}/lib/modules/"

echo "Copying /lib/firmware ..."
cp -a "${TMP}/lib/firmware/." "${DEST}/lib/firmware/"

echo "Copying low-level firmware ..."
cp "${FLASH_PKG}/aboot.bin"      "${DEST}/aboot.bin"
cp "${FLASH_PKG}/gpt_both0.bin"  "${DEST}/gpt_both0.bin"
cp "${FLASH_PKG}/hyp.mbn"        "${DEST}/hyp.mbn"
cp "${FLASH_PKG}/rpm.mbn"        "${DEST}/rpm.mbn"
cp "${FLASH_PKG}/sbl1.mbn"       "${DEST}/sbl1.mbn"
cp "${FLASH_PKG}/tz.mbn"         "${DEST}/tz.mbn"
# board config (cdt)
[ -e "${FLASH_PKG}/sbc_1.0_8016.bin" ] && cp "${FLASH_PKG}/sbc_1.0_8016.bin" "${DEST}/sbc_1.0_8016.bin"

echo "Done. ${DEST} populated:"
ls -R "${DEST}"
