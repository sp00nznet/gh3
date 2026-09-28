#!/bin/sh
# runall.sh <run> [FIRST] [ENV=..]: play the whole setlist, restarting the game after
# each hang and resuming at the next song, then write the report.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
RUN=$1; F=${2:-1}; shift; [ $# -gt 0 ] && shift
while :; do
    FIRST=$F sh $H/songloop.sh $RUN 99 "$@"; rc=$?
    [ $rc = 3 ] || break
    F=$(cat $L/songs/$RUN/.next); echo "resuming at song $F"
done
python $H/report.py $L/songs/$RUN
