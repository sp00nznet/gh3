#!/bin/sh
# botsong.sh <run> [ENV=..]: boot, bot_play on, Quickplay -> Easy -> Slow Ride.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}; W=$(cygpath -m "$L")
sh $H/boot.sh "$@" PS3_DEBUG=$W/dbg.txt >/dev/null 2>&1; sh $H/bot.sh
sh $H/press.sh w25 0x0040:3 0x0040:3 0x4000:6 w3 0x4000:6 w5 0x4000:6 w1 >/dev/null 2>&1
