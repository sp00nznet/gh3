#!/bin/sh
# press.sh <mask|wN>...: drive the running gh3 via pad.txt, then save latest frame.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
W=$(cygpath -m "$L")
press() { echo $1 | tr : " " > $L/pad.txt; n=0; while [ -s $L/pad.txt ] && [ $n -lt 60 ]; do sleep 1; n=$((n+1)); done; sleep 3; }
for a in "$@"; do case $a in w*) sleep ${a#w} ;; *) press $a ;; esac; done
sleep 8
f=$(ls -t $L/frames | grep ppm | head -1)
python -c "from PIL import Image; Image.open('$W/frames/$f').save('$W/frames/latest.png')"
echo "latest $f"
