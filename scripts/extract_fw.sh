#!/bin/sh -e

# Low-level firmware is taken pre-extracted from the device flash package
# (see scripts/extract_prebuilt.sh) instead of being downloaded from the
# DragonBoard 410c archive. This keeps the build fully offline/self-contained
# and guarantees the exact blobs shipped with the device.

PREBUILT=${PREBUILT=prebuilt/ufi103s}

[ -d "${PREBUILT}" ] || { echo "ERROR: ${PREBUILT} not found; run scripts/extract_prebuilt.sh first"; exit 1; }

mkdir -p files

cp ${PREBUILT}/aboot.bin         files/aboot.bin
cp ${PREBUILT}/gpt_both0.bin     files/gpt_both0.bin
cp ${PREBUILT}/hyp.mbn           files/hyp.mbn
cp ${PREBUILT}/rpm.mbn           files/rpm.mbn
cp ${PREBUILT}/sbl1.mbn          files/sbl1.mbn
cp ${PREBUILT}/tz.mbn            files/tz.mbn
# board config (cdt) - present in the device flash package
[ -e ${PREBUILT}/sbc_1.0_8016.bin ] && cp ${PREBUILT}/sbc_1.0_8016.bin files/sbc_1.0_8016.bin

echo "Low-level firmware copied from ${PREBUILT}"
