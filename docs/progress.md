# Progress log

Newest first. Fixes are in [ps3recomp](https://github.com/sp00nznet/ps3recomp) unless noted.

## 2026-09-28: the song freeze, fixed

About one song in 10-15 froze: the main thread waited forever on SPURS jobs
that a job-manager SPU had claimed and then abandoned. That SPU had died in
the job manager's own assert (`heqi` at jobpm 0x820, "DMA tag <= 31") while
walking its 7-entry buffer loop (0xAA0..0xB58) with a loop counter of 8, 9, 10.

The counter had been clobbered by the job, not by the loop. Some jobs arrive
in local store at run time and were never lifted, so they run in the SPU
interpreter, which handed back to compiled code only at a lifted function
*entry*. A job's return point (0xBA8) sits mid-function, so the interpreter
ran on through the job manager's own code, into the next buffer loop, until
it met a lifted entry (0xB28). The runtime then ran that stretch again, now
with the job's registers. The telltale log line:
`drain-resume return_pc=0x00BA8 at lifted entry 0x00B28`.

Fix (ps3recomp 0f22fa9 + fff4b49): the interpreter also stops at the pending call's
return point. Then the whole 45-song setlist played with no freeze (it had
frozen on song 9 in the run before).

The harness now reads each song's "NN% NOTES HIT" badge with Windows' own
OCR (`tools/harness/ocr.ps1`) and flags anything under 100%: a miss means
frames came late, which is what 60 fps work has to fix.

## 2026-09-27: setlist harness, first full pass

`tools/harness/songloop.sh <run> <n>` plays the Quickplay setlist with the bot
and `report.py` writes a per-song HTML report (contact sheet, fps, flagged
frames). This save unlocks 8 Quickplay songs (tiers 1-2, Slow Ride to
Barracuda); at the end of the list DOWN does nothing and the loop replays the
last song, so pass n=8. More songs need Career progress or the unlock cheat
(`unlock_cheat` / `Cheat_UnlockAll`), which runs scripts rather than setting a
flag.

First pass: all 8 songs complete (bot 83-90% notes hit at ~30 fps), no black,
flat or missing-highway frames. Two findings:

- **Hang:** the second Barracuda of a session froze ~60 s in. The main thread
  sits in `func_0001A66C` waiting for a SPURS job slot; slots 27 and 34 of the
  job array (0x13598A00) stay marked in progress (`+0x1C = 1`) while the
  job-policy SPUs keep polling -- the boot-time job-stall shape again. State
  saved in `scratch/logs/hang1/`.
- **Bot vs frame rate:** the bot feeds one note event per frame, so under host
  load (<~20 fps) it misses dense passages and can fail a song. The harness
  records that and takes NEW SONG.

## 2026-09-27: the bot plays, and songs have sound

**Autoplay.** GH3 ships its own bot: `player1_status.bot_play`, read once by
`gem_scroller` when a song starts, which then feeds the note iterator from
the chart instead of the pad. `tools/harness/bot.sh` finds that struct
member in guest memory through the debug console (`find32 20D0AD37`, type
byte 0x81) and sets it; `botsong.sh` boots, sets it in the menus and starts
Slow Ride. The bot builds a 4x multiplier, fills star power ("Star Power
Ready", tubes lit), keeps the rock meter green and reaches the song end.

**Static in songs** was the audio engine starving, not a crowd sample.
GH3 mixes with FMOD, which runs as a SPURS task on an SPU. Fixes, all in
ps3recomp:

| Cause | Fix |
|---|---|
| The cellAudio mixer ran ~20% fast (225 blocks/s, not 187.5) and the device dropped the surplus | pace to WASAPI padding |
| PPU event-flag set/clear raced the SPU task library's atomics on the same line; a lost wait deadlocked FMOD at boot in some runs | RMW under the lock-line lock |
| Four idle SPURS job pollers hammered the lock-line spinlock; FMOD's task waited 25-40 ms | TTAS lock, yield on idle poll |
| FMOD's SPU task was ~90% busy, a third of it runtime overhead (byte-loop shufb, out-of-line LS load/store, an LS watchpoint check on every access) | pshufb shufb (`-msse4.1`), inlined LS paths |

Song silence went from ~55% to ~3% of audio blocks. It rises again when the
host is saturated (other builds running), because the FMOD task needs a
free core.

## 2026-09-25: gameplay renders complete at ~40 fps

2026-09-25: the save loads, the menus work, and Quickplay → Easy → Slow Ride
plays with the venue, band, highway, fret buttons, strings, gems, HUD and audio.

**Frame rate** went from 7–9 fps to about 40 fps in gameplay:

| Cause | Fix |
|---|---|
| Nothing was optimised. The CMake caches carry empty `CMAKE_{C,CXX}_FLAGS_RELEASE`, and clang-cl without `/O` is `/Od` | `-O2` added explicitly here and in ps3recomp |
| ~700 `getenv()` diagnostic gates, several per draw or per syscall. The UCRT scan was ~30% of the main PPU thread and ~35% of the RSX thread | `__imp_getenv` is a lock-free cache (boot_main.cpp) |
| `[RSX null]` / `[evt]` lines printed every frame through stderr's lock | gated behind `ps3_log_verbose()` |

Now the main PPU thread spends most of a frame in `func_0001A66C`, which waits
for the SPU job queue to drain (a 100 µs usleep poll). The SPURS job threads
are the next bottleneck.

**The venue in gameplay** was black. The full-screen draw over it (`pso_key`
`ab823ddcaca097e6`) is the `bg_viewport` ViewportElement, parked off-screen in
`ui_clip_root`. The engine hides it with a scissor of width and height 0. The
live renderer read a zero-size scissor as "no scissor", so the empty
render texture covered the screen. A written scissor of zero now clips everything.

**The fretboard** (fret buttons, strings, fret lines) was missing. Those sprites'
fragment programs sample with `TXB` (LOD bias), which the FP decompiler didn't
handle, so they came out with alpha 0. `TXB`/`TXL` now map to
`SampleBias`/`SampleLevel`.

## 2026-09-24: intro movies play, reaches attract mode

2026-09-24: the full boot runs unattended. The four Bink movies (ATVI, RO_LOGO,
NS_LOGO, INTRO) play with sound. The title screen comes up, and after the idle
timeout the game loads the attract demo: Art Deco venue, *The Seeker*, and the
full band. It then shows attract mode's "Press any button to rock" overlay. The
venue issues about 200 draw groups a frame, but they don't reach the screen, so
the overlay sits on black. That's next.

What stood between the title screen and attract mode, in order (fixes are in
ps3recomp unless noted):

| Symptom | Cause |
|---|---|
| Movies never opened | USRDIR flattening mapped to `<root>/USRDIR`, but this tree is disc layout (`PS3_GAME/USRDIR`) |
| Movies rendered solid green | `fread` past the CRT buffer goes straight to `ReadFile`, and a kernel write into a not-yet-committed VM page fails. Bink got a short read, flagged ReadError and skipped every frame |
| Movie froze at frame 60 | Lifter replaced a spill reload `ld r23,0x918(r1)` with the entry value of r23 from its restore slot (0x888). Bink's row loop never hit zero |
| Froze on job 41 | A new SPU job body (0x14B91980), captured with `SPU_DUMP_OVL` and lifted as image 12 (this repo) |
| Havok collide task spun forever | `MFC_RdAtomicStat` returned 0 after GETLLAR; hardware returns 4, and Havok's allocator loops until it sees it |
| Physics step never finished | `cellSpursCreateTask` never freed a task id. Havok creates one per step, so step 128 failed |
| Integrate task spun on a ticket lock | PPU `cellSyncMutexUnlock` (HLE CAS) raced SPU PUTLLC on the same mutex and was overwritten |
| Run crawled at 4 fps unattended | Monitor asleep throttles vsync'd Present; the runtime now keeps the display awake |
| Whole process froze at 0% CPU | The watchdog printed while a thread was suspended, and that thread held stderr's lock |

## Day one: first boot

| Step | State |
|---|---|
| `EBOOT.BIN` → plain ELF | **done** — disc SELF (`type=APP`, key_rev 0x1c), no NPDRM |
| Imports | **done** — 229 across 18 libraries, 204 named (89%) |
| Function discovery | **done** — 28,162 found, 27,137 `.opd` descriptors as ground truth |
| PPU lift | **done** — 28,987 functions, 6 chunks, 193 MB of C++, 6 continuation warnings |
| Build & link | **done** — first attempt, 13/13, **nothing title-specific in the tree** |
| Boot | **runs** — 17 system modules, `cellGame` check passes, `sceNp` init, window open, ~63 fps |
| Assets | **loaded** — 14 files, every read complete, zero failures |
| Render | **draws** — the animated loading record is on screen |
| Frontend | **not reached** — with `PS3_NULL_SWEEP=1` the guest is healthy and the blocker is the decompression wait; without it a bad container pointer memsets 82 MB over the image |

The startup stall that followed, and how it was traced, is in
[boot-investigation.md](boot-investigation.md).
