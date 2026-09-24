#!/bin/sh
# Regenerate everything git-ignored: imports.json, the lifted PPU tree, and the
# HLE NID table. Run from the repo root.
set -e
PS3RECOMP="${PS3RECOMP:-/g/recomp/ps3}"

# The import trampolines (.lib.stub) live at 0x9B2298..0x9B3F38, immediately
# after .text and .fini. --code-end has to sit just PAST them, not before, or
# --hle-stubs has nothing to rewrite; and not further, because everything above
# is .rodata packed into the same R-X segment -- the data-as-code trap that cost
# flOw and YDKJ multi-gigabyte lifts.
CODE_END=0x9B3F38

python "$PS3RECOMP/tools/gen_imports.py" game/EBOOT.elf -o imports.json
python "$PS3RECOMP/tools/find_functions.py" game/EBOOT.elf --output analysis/functions.json

rm -rf src/recomp src/gen && mkdir -p src/recomp src/gen
python "$PS3RECOMP/tools/ppu_lifter.py" game/EBOOT.elf \
    --functions analysis/functions.json \
    --hle-stubs imports.json \
    --code-end "$CODE_END" \
    -o src/recomp

python "$PS3RECOMP/tools/gen_hle_nids.py" --all --out src/gen/ppu_hle_nids.cpp

# ---- SPU -------------------------------------------------------------------
# GH3 has SIX SPU images and they come from two different places.
#
# Five are ordinary embedded ELFs in the EBOOT, which extract_spu_images.py
# finds; the title creates two of them as SPURS *tasks* (cellSpursCreateTask,
# entries 0x101A3380 / 0x101C7280).
#
# The sixth is the job library's SPURS WORKLOAD policy module -- a RAW blob the
# title builds in main memory (cellSpursAddWorkload pm=0x1010B200, 6720 bytes),
# so the extractor cannot see it and the only place its bytes exist is the
# moment cellSpurs hands it over. Capture it from a run:
#
#   SPU_DUMP_MISS=spu_miss ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf
#
# and re-lift below. Without it the workload dispatch MISSes and the job
# library's SPU side never runs at all, which is what left every decompression
# job submitted, counted and never retired.
python "$PS3RECOMP/tools/extract_spu_images.py" game/EBOOT.elf --out analysis/spu

rm -rf src/spu_gen && mkdir -p src/spu_gen
python "$PS3RECOMP/tools/build_spu_workloads.py" \
    --images analysis/spu --lifted src/spu_gen \
    --out src/spu_gen/spu_workloads.c \
    --register-fn gh3_spu_register_all --constructor --title gh3

# ---- the job library's workload policy module (raw capture) ----------------
# Lifted at base 0: a workload PM is loaded at LS 0 and entered at its first
# instruction, so the lifted addresses equal the link-time ones.
JOBPM=spu_miss/spujob_21F48A8621295E5A_6720.bin
if [ -f "$JOBPM" ]; then
    python "$PS3RECOMP/tools/find_spu_functions.py" "$JOBPM" --raw --base 0         --out spu_miss/jobpm_funcs.json
    rm -rf src/spu_gen/jobpm && mkdir -p src/spu_gen/jobpm
    python "$PS3RECOMP/tools/spu_lifter.py" "$JOBPM" --base 0         --functions spu_miss/jobpm_funcs.json         --symbol-prefix jobpm_ -o src/spu_gen/jobpm
    echo "NOTE: re-add the jobpm block to src/spu_gen/spu_workloads.c --"
    echo "      build_spu_workloads.py globs *.elf and cannot see a raw blob."
else
    echo "missing $JOBPM -- capture it with SPU_DUMP_MISS first"
fi

# ---- the job BODY the PM streams in as an overlay --------------------------
# The workload PM DMAs this from guest 0x1011A300 (0x1790 bytes) to LS 0x5000
# and branches into it, so it is never dispatched and the workload registry
# never sees it. Without a lifted body the SPU INTERPRETS it: correct, but far
# too slow -- 9.5 minutes of wall clock did not finish one decompression.
# Lifted, the same job completes in seconds and the boot advances past the
# GLOBAL zone. Extracted straight from the EBOOT (it is file-backed).
JOBBODY=spu_miss/jobbody_1011A300_6544.bin
if [ -f "$JOBBODY" ]; then
    # --base 0x5000: it is loaded at LS 0x5000, so lifted addresses must equal
    # the local-store ones for the indirect-branch lookup to find them.
    python "$PS3RECOMP/tools/find_spu_functions.py" "$JOBBODY" --raw --base 0x5000         --out spu_miss/jobbody_funcs.json
    rm -rf src/spu_gen/jobbody && mkdir -p src/spu_gen/jobbody
    python "$PS3RECOMP/tools/spu_lifter.py" "$JOBBODY" --base 0x5000         --functions spu_miss/jobbody_funcs.json         --symbol-prefix jobbody_ -o src/spu_gen/jobbody
    echo "NOTE: re-add the jobbody block to src/spu_gen/spu_workloads.c --"
    echo "      it registers under image 6, alongside the PM."
fi

# ---- the other job bodies (overlays at LS 0x5000) ---------------------------
# The job PM streams whichever job's code it is about to run into LS 0x5000,
# so each body is its own overlay image keyed by the EA it is GETted from (see
# spu_workloads.c). Capture them all from a run that reaches the frontend:
#
#   SPU_DUMP_OVL=spu_miss/ovl ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf
#
# 0x1011A300 is the decompressor, lifted above as jobbody.
# 0x14B91980 (job 41) first streams during the Bink intro; a capture that
# stops at the title screen misses it, so let the run reach attract mode.
for J in spu_miss/ovl/ovl_*.bin; do
    [ -f "$J" ] || continue
    EA=$(basename "$J" .bin | sed 's/ovl_//')
    [ "$EA" = "1011A300" ] && continue
    python "$PS3RECOMP/tools/find_spu_functions.py" "$J" --raw --base 0x5000 \
        --out "spu_miss/ovl/job_${EA}_funcs.json"
    rm -rf "src/spu_gen/job_$EA" && mkdir -p "src/spu_gen/job_$EA"
    python "$PS3RECOMP/tools/spu_lifter.py" "$J" --base 0x5000 \
        --functions "spu_miss/ovl/job_${EA}_funcs.json" \
        --symbol-prefix "job_${EA}_" -o "src/spu_gen/job_$EA"
done
