#!/bin/sh
# unlock.sh: set every QB 'unlocked' member to 1 in a running gh3 started with
# PS3_DEBUG=$W/dbg.txt (debug console 'qbset'). Songs, tiers, venues, gear.
L=${GH3_LOGS:-/g/recomp/ps3games/gh3/scratch/logs}
: > $L/dbg.txt.out; echo "qbset FEF4E1E8 1" > $L/dbg.txt
for i in $(seq 1 60); do grep -q "member(s)" $L/dbg.txt.out 2>/dev/null && break; sleep 1; done
grep "member(s)" $L/dbg.txt.out
