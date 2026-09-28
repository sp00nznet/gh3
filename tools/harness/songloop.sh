#!/bin/sh
# songloop.sh <run> <nsongs> [ENV=..]: boot, unlock, bot_play on, Quickplay ->
# Easy, then play the setlist: each song to its results screen, back to the
# setlist, next one down. Per song: frames (PNG, every ~10 s) in
# $L/songs/<run>/NN/ and fps/draws samples in NN/fps.txt.
#   FIRST=n   start at the n-th song (resume); earlier song dirs are kept
# Exit: 0 at the end of the setlist, 3 when the game hung (NN/HANG, job-slot
# dump in NN/hang_slots.txt, next song in $OUT/.next -- runall.sh resumes).
# A song ends when the fret buttons leave the screen (screen.py).
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}; W=$(cygpath -m "$L")
RUN=$1; N=$2; shift 2
FIRST=${FIRST:-1}
OUT=$L/songs/$RUN; [ $FIRST = 1 ] && rm -rf "$OUT"; mkdir -p "$OUT"
EVERY=${EVERY:-300} sh $H/boot.sh $RUN PS3_DEBUG=$W/dbg.txt "$@" >/dev/null 2>&1
sh $H/press.sh 0x2000:6 w4 >/dev/null 2>&1   # CIRCLE: out of Career's band-name prompt if a boot press opened it
sh $H/unlock.sh                               # every 'unlocked' tag: the whole setlist
sh $H/bot.sh
sh $H/press.sh w5 0x0040:3 0x0040:3 0x4000:6 w3 0x4000:6 w5 >/dev/null 2>&1   # -> setlist
title() { powershell -c "(Get-Process gh3 -ErrorAction SilentlyContinue).MainWindowTitle" | tr -d '\r'; }
# Move new frames into a dir as 640x360 PNGs.
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
NAV=$OUT/_nav; mkdir -p $NAV
# DOWN once, confirmed: the setlist must change. Returns 1 at the bottom of the
# list (three presses that move nothing).
down() {
    for try in 1 2 3; do
        sleep 12; collect $NAV; before=$(ls $NAV/*.png 2>/dev/null | tail -1)
        sh $H/press.sh 0x0040:3 w12 >/dev/null 2>&1; collect $NAV; after=$(ls $NAV/*.png 2>/dev/null | tail -1)
        moved=1; [ -n "$before" ] && [ -n "$after" ] && ! python $H/screen.py --same "$before" "$after" && moved=0
        rm -f $NAV/*.png; [ $moved = 0 ] && return 0
    done
    return 1
}
collect $NAV; rm -f $NAV/*.png                # boot and menu frames are not a song
for k in $(seq 2 $FIRST); do down || { echo "setlist shorter than FIRST=$FIRST"; exit 1; }; done
for i in $(seq $FIRST $((FIRST + N - 1))); do
    d=$OUT/$(printf %02d $i)
    if [ $i -gt $FIRST ] && ! down; then echo "end of the setlist after song $((i - 1))"; break; fi
    rm -rf $d; mkdir -p $d
    sh $H/bot.sh >> $d/fps.txt              # every song: the flag may be reset in between
    sh $H/press.sh 0x4000:6 >/dev/null 2>&1                          # start it
    t0=$(date +%s); seen=0; gone=0; frames=0; still=0
    # Over when the fret buttons have been on screen and then are gone from two
    # consecutive frames (results, failure, pause -- anything but the highway).
    while [ $(( $(date +%s) - t0 )) -lt 600 ]; do
        sleep 10; collect $d
        tasklist | grep -q gh3.exe || { echo "gh3 exited" >> $d/fps.txt; exit 1; }
        n=$(ls $d/*.png 2>/dev/null | wc -l)
        if [ $n = $frames ]; then still=$((still + 1)); else still=0; frames=$n; fi
        if [ $still -ge 8 ]; then
            # No new frame in ~90 s: the game hung. Keep the SPURS job table
            # (the known hang leaves two job slots marked in progress).
            echo "HANG: no new frame for ~90 s" >> $d/fps.txt; : > $d/HANG
            : > $L/dbg.txt.out; echo "mem 13598A00 1984" > $L/dbg.txt; sleep 5; cp $L/dbg.txt.out $d/hang_slots.txt
            : > $L/dbg.txt.out; echo "jobwatch $(cygpath -m $d)/jobwatch.txt" > $L/dbg.txt; sleep 10   # JOBWATCH runs only
            cp $L/$RUN.log $d/run.log 2>/dev/null   # the resume truncates it
            echo $((i + 1)) > $OUT/.next; echo "song $i: HANG after $(( $(date +%s) - t0 ))s"
            taskkill //F //IM gh3.exe >/dev/null 2>&1; exit 3
        fi
        last=$(ls $d/*.png 2>/dev/null | tail -1); [ -n "$last" ] || continue
        state=$(python $H/screen.py "$last" | cut -d' ' -f1)
        echo "$(( $(date +%s) - t0 ))s $state $(title)" >> $d/fps.txt
        if [ "$state" = play ]; then seen=1; gone=0
        elif [ $seen = 1 ]; then gone=$((gone + 1)); [ $gone -ge 2 ] && break; fi
    done
    [ $seen = 0 ] && { echo "TIMEOUT: song never started" >> $d/fps.txt; break; }
    [ $gone -ge 2 ] || echo "TIMEOUT: song never ended" >> $d/fps.txt
    sleep 8; collect $d
    last=$(ls $d/*.png 2>/dev/null | tail -1)
    if [ -n "$last" ] && [ "$(python $H/screen.py "$last" | cut -d' ' -f1)" = failed ]; then
        # The bot misses when the game drops well below 30 fps (it feeds one
        # note event per frame). Record it and take NEW SONG, not RETRY.
        echo "FAILED" >> $d/fps.txt
        sh $H/press.sh 0x0040:3 w2 0x4000:6 w8 >/dev/null 2>&1
        collect $d; echo "song $i: FAILED after $(( $(date +%s) - t0 ))s"; continue
    fi
    # Results page: read the "NN% NOTES HIT" badge. Under 100% = the bot missed,
    # which means frames came late (host load), not wrong notes.
    notes=?
    if [ -n "$last" ] && python $H/screen.py --badge "$last" $d/badge.png; then
        notes=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w $H/ocr.ps1)" "$(cygpath -w $d/badge.png)" |
                grep -o '[0-9]\{1,3\}%' | head -1)
    fi
    echo "NOTES ${notes:-?}" >> $d/fps.txt
    sh $H/press.sh 0x4000:6 w6 >/dev/null 2>&1                       # CONTINUE
    collect $d
    last=$(ls $d/*.png 2>/dev/null | tail -1)
    if [ -n "$last" ] && [ "$(python $H/screen.py "$last" | cut -d' ' -f1)" = hiscore ]; then
        sh $H/press.sh 0x0008:6 w8 >/dev/null 2>&1                   # accept the high-score name
        collect $d
        # No new entry (the table is already full of better scores): the same
        # screen is view-only and START does nothing -- back out of it.
        last=$(ls $d/*.png 2>/dev/null | tail -1)
        if [ -n "$last" ] && [ "$(python $H/screen.py "$last" | cut -d' ' -f1)" = hiscore ]; then
            sh $H/press.sh 0x2000:6 w8 >/dev/null 2>&1; collect $d
        fi
    fi
    echo "song $i: $(( $(date +%s) - t0 ))s, $(ls $d/*.png 2>/dev/null | wc -l) frames, notes ${notes:-?}"
done
rm -f $OUT/.next
taskkill //F //IM gh3.exe >/dev/null 2>&1
exit 0
