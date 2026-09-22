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
# Unlike Simpsons (whose SPURS job binaries are raw blobs built in main memory
# and have to be captured at dispatch with SPU_DUMP_MISS), GH3's five SPU images
# are ordinary embedded ELFs in the EBOOT, so extract_spu_images.py finds them
# and no capture run is needed. The title creates them as SPURS *tasks*
# (cellSpursCreateTask, entries 0x101A3380 / 0x101C7280), which is a different
# path from the job-chain dispatch SPU_DUMP_MISS hooks -- so that env would
# never have produced anything here.
python "$PS3RECOMP/tools/extract_spu_images.py" game/EBOOT.elf --out analysis/spu

rm -rf src/spu_gen && mkdir -p src/spu_gen
python "$PS3RECOMP/tools/build_spu_workloads.py" \
    --images analysis/spu --lifted src/spu_gen \
    --out src/spu_gen/spu_workloads.c \
    --register-fn gh3_spu_register_all --constructor --title gh3
