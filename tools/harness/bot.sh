#!/bin/sh
# bot.sh: set bot_play = 1 in every QB struct component named bot_play
# (player1_status / player2_status) of a running gh3 started with
# PS3_DEBUG=$W/dbg.txt. A component is 16 bytes: type 0x81 (int), name
# checksum 0x20D0AD37, value, next -- so the value is at hit+4.
H=$(cd "$(dirname "$0")" && pwd)
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
dbg() { : > $L/dbg.txt.out; echo "$1" > $L/dbg.txt; for i in $(seq 1 30); do grep -q "hit(s)\|\] = \|0x.*|" $L/dbg.txt.out 2>/dev/null && break; sleep 1; done; cat $L/dbg.txt.out; }
n=0
for a in $(dbg "find32 20D0AD37" | grep -o "0x[0-9A-F]\{8\}"); do
    pre=$(printf "%X" $((a - 4)))
    dbg "mem $pre 4" | grep -q " 00 81 00 00 " || continue
    dbg "poke32 $(printf "%X" $((a + 4))) 1" >/dev/null; n=$((n + 1))
done
echo "bot_play set in $n struct(s)"
