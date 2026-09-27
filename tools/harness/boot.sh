#!/bin/sh
# boot.sh <run-name> [ENV=VAL...]: boot gh3 quietly (PS3_VERBOSE=0), skip the
# intro movies with START/CROSS until the progress save has loaded. Then drive
# it with press.sh. Frames every 150 flips in frames/.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
W=$(cygpath -m "$L")
RUN=$1; shift
taskkill //F //IM gh3.exe >/dev/null 2>&1; sleep 2
cd "$H/../.."
rm -f $L/run*.log $L/pad.txt $L/frames/*; mkdir -p $L/frames; touch $L/pad.txt
(env PS3_VERBOSE=0 PAD_FILE=$W/pad.txt LD_FRAME_DUMP=$W/frames LD_FRAME_DUMP_EVERY=${EVERY:-150} PS3_NULL_SWEEP=1 \
  PS3_VFS_ROOT=vfs RSX_LIVE_DRAW=1 "$@" timeout 9000 ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf > $L/$RUN.log 2>&1 &)
until grep -aq "INTRO.BIK" $L/$RUN.log; do sleep 5; done
b=0x0008
for i in $(seq 1 60); do
    sleep 8; echo $b > $L/pad.txt; [ $b = 0x0008 ] && b=0x4000 || b=0x0008
    [ $(grep -ac "GPROGRESS006Q' (new=0)" $L/$RUN.log) -ge 2 ] && { sleep 10; break; }
done
echo "loaded after $i presses"
