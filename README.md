# gh3 — Guitar Hero III: Legends of Rock (PS3), static recompilation

`BLUS30074`, disc release. Recompiled with
[ps3recomp](https://github.com/sp00nznet/ps3recomp).

![Guitar Hero III running natively on Windows: Slow Ride in the Backyard](docs/media/hero.gif)

| | |
|---|---|
| ![Title screen](docs/media/title.png) | ![Main menu](docs/media/main_menu.png) |
| ![Setlist](docs/media/setlist.png) | ![Song intro](docs/media/song_intro.png) |
| ![Gameplay](docs/media/gameplay_1.png) | ![Gameplay](docs/media/gameplay_2.png) |

The window title shows the presented FPS, the draws in the last frame and the
backbuffer size, e.g. `Guitar Hero III: Legends of Rock | FPS: 40.12 | draws: 1492 | 1280x720`.

## Status

Boots through the intro movies, menus and save load into gameplay, with the
venue, band, highway, fretboard, gems, HUD, star power and song audio.

**Playthrough (2026-09-27):** GH3's own bot (`bot_play`) played the entire
Quickplay setlist, all 45 songs on Easy, unattended with
[`tools/harness`](tools/harness):

| | |
|---|---|
| Songs completed | 41 of 45 on the first pass; the bot hits 83-100% of notes |
| Hangs | 4 (songs 25, 27, 34, 42), about one per 10 songs, each 30-60 s into a song |
| Rendering | no black, blank or missing-highway frames (8 flagged frames are dark intros) |
| Frame rate | ~40 fps in songs, 50-60 in menus |

Every hang has the same shape: two SPURS jobs are taken by a job-policy SPU and
never completed, and the main thread waits on them for good (details in
[docs/progress.md](docs/progress.md)).

### What "complete" still needs

1. **The job hang.** One freeze per ~10 songs is not playable. Next: log each
   SPURS job's claim and completion, catch which job is abandoned and why.
2. **Real input.** The runtime reads XInput pads (plus a keyboard fallback),
   so an Xbox-style controller works as a PS3 pad today. Guitars need:
   report the pad as a guitar (`pclass_type`), map frets, strum, whammy and
   tilt, and read a PS3 guitar's HID dongle or Bluetooth, which XInput never
   sees; a PC guitar that speaks XInput only needs the mapping.
3. **Timing.** A rhythm game lives on audio/video/input latency: check the
   in-game calibration against real play. Song audio was starving until
   2026-09-27 (fixed in ps3recomp); confirm by ear on a quiet machine.
4. **60 fps.** The SPURS job threads are the bottleneck. The bot also plays
   better with frame rate: it feeds one note event per frame.
5. **Modes beyond Quickplay.** Career (boss battles, encores, cutscenes,
   progress saves), co-op and local multiplayer. Online is out of scope.

- [docs/progress.md](docs/progress.md): what was fixed at each milestone
- [docs/boot-investigation.md](docs/boot-investigation.md): the startup stall, traced

## Why this title

Picked over Rock Band 3 on measurement rather than taste. Both are "big game,
simple engine" on paper; they are not the same target:

| | code | functions | SPU markers | imports |
|---|---|---|---|---|
| Simpsons Arcade *(playable)* | 1.3 MB | 5,019 | few | — |
| **Guitar Hero III** | 9.7 MB | **28,987** | **7** | 229 |
| Rock Band 3 | 13.6 MB | 32,128 | **104** | 297 |

Rock Band 3 runs Sony's MultiStream (`cellMS*`) audio middleware on the SPUs —
104 markers — and in a rhythm game the audio path *is* the critical path. That
is the same shape that has Virtua Fighter 5 and Tokyo Jungle stuck. GH3 has 7.

## Building

```bash
./tools/relift.sh                     # imports.json, functions.json, lifted tree, NID table
cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
cmake --build build
PS3_NULL_SWEEP=1 PS3_VFS_ROOT=vfs RSX_LIVE_DRAW=1 ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf
```

`--code-end 0x9B3F38` in `relift.sh` is load-bearing: it sits just past the
`.lib.stub` import trampolines (`0x9B2298..0x9B3F38`) so `--hle-stubs` has
something to rewrite, and no further, because everything above is `.rodata` in
the same R-X segment — the data-as-code trap that cost flOw and YDKJ
multi-gigabyte lifts.

`PS3_NULL_SWEEP=1` is needed to boot; see the boot investigation.

## Legal

No game code, assets or keys here, only analysis and build configuration.
Supply your own legally dumped disc. The code is under the [MIT license](LICENSE).
The screenshots and GIF are from Guitar Hero III (© Activision), shown only to
document progress.
