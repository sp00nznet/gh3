#!/bin/sh
# fps.sh <run> [ENV=..]: bot song, then 6 title samples 5 s apart from 40 s in.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
EVERY=100000 timeout 900 sh $H/botsong.sh "$@" >/dev/null 2>&1
sleep 40
for i in 1 2 3 4 5 6; do powershell -c "(Get-Process gh3 -ErrorAction SilentlyContinue).MainWindowTitle" | tr -d '\r' | sed 's/.*FPS: \([0-9.]*\) | draws: \([0-9]*\).*/\1 fps \2 draws/'; sleep 5; done
taskkill //F //IM gh3.exe >/dev/null 2>&1
