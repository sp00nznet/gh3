# Progress log

Newest first. Fixes are in [ps3recomp](https://github.com/sp00nznet/ps3recomp) unless noted.

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
