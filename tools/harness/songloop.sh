#!/bin/sh
# songloop.sh <run> <nsongs> [ENV=..]: boot, bot_play on, Quickplay -> Easy,
# then play the setlist from the top: each song to its results screen, back to
# the setlist, next one down. Per song: frames (PNG, every ~10 s) in
# $L/songs/<run>/NN/, fps/draws samples in NN/fps.txt, and index.html
# (report.py). Stops at the first song that never starts.
# The end of a song is the fret buttons leaving the screen (screen.py).
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}; W=$(cygpath -m "$L")
RUN=$1; N=$2; shift 2
OUT=$L/songs/$RUN; rm -rf "$OUT"; mkdir -p "$OUT"
EVERY=${EVERY:-300} sh $H/boot.sh $RUN PS3_DEBUG=$W/dbg.txt "$@" >/dev/null 2>&1
sh $H/bot.sh
sh $H/press.sh w25 0x0040:3 0x0040:3 0x4000:6 w3 0x4000:6 w5 >/dev/null 2>&1   # -> setlist
title() { powershell -c "(Get-Process gh3 -ErrorAction SilentlyContinue).MainWindowTitle" | tr -d '\r'; }
# Move new frames into a song dir as 640x360 PNGs.
collect() { python - "$L/frames" "$1" <<'EOF'
import os, sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
for f in sorted(os.listdir(src)):
    if f.startswith('frame_') and f.endswith('.ppm'):
        p = os.path.join(src, f)
        try:
            Image.open(p).resize((640, 360)).save(os.path.join(dst, f[:-4] + '.png'))
            os.remove(p)
        except OSError:
            pass            # still being written; next pass takes it
EOF
}
collect "$OUT"; rm -f "$OUT"/*.png          # boot and menu frames are not a song
for i in $(seq 1 $N); do
    d=$OUT/$(printf %02d $i); mkdir -p $d
    [ $i -gt 1 ] && sh $H/press.sh 0x0040:3 w2 >/dev/null 2>&1     # DOWN to the next song
    sh $H/bot.sh >> $d/fps.txt              # every song: the flag may be reset in between
    sh $H/press.sh 0x4000:6 >/dev/null 2>&1                          # start it
    t0=$(date +%s); seen=0; gone=0
    # Over when the fret buttons have been on screen and then are gone from two
    # consecutive frames (results, failure, pause -- anything but the highway).
    while [ $(( $(date +%s) - t0 )) -lt 600 ]; do
        sleep 10; collect $d
        tasklist | grep -q gh3.exe || { echo "gh3 exited" >> $d/fps.txt; exit 1; }
        last=$(ls $d/*.png 2>/dev/null | tail -1); [ -n "$last" ] || continue
        state=$(python $H/screen.py "$last" | cut -d' ' -f1)
        echo "$(( $(date +%s) - t0 ))s $state $(title)" >> $d/fps.txt
        if [ "$state" = play ]; then seen=1; gone=0
        elif [ $seen = 1 ]; then gone=$((gone + 1)); [ $gone -ge 2 ] && break; fi
    done
    if [ $seen = 0 ]; then       # locked, or past the last unlocked song: the run is over
        echo "TIMEOUT: song never started -- end of the playable setlist" >> $d/fps.txt; break
    fi
    [ $gone -ge 2 ] || echo "TIMEOUT: song never ended" >> $d/fps.txt
    sleep 8; collect $d
    sh $H/press.sh 0x4000:6 w10 0x0008:6 w10 >/dev/null 2>&1          # CONTINUE, accept high score
    collect $d
    echo "song $i: $(( $(date +%s) - t0 ))s, $(ls $d/*.png 2>/dev/null | wc -l) frames"
done
taskkill //F //IM gh3.exe >/dev/null 2>&1
python $H/report.py $OUT
