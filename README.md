# gh3 — Guitar Hero III: Legends of Rock (PS3), static recompilation

`BLUS30074`, disc release. Recompiled with
[ps3recomp](https://github.com/sp00nznet/ps3recomp). Day one of this port.

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

## Status: boots, opens a window, stops before loading its assets

| Step | State |
|---|---|
| `EBOOT.BIN` → plain ELF | **done** — disc SELF (`type=APP`, key_rev 0x1c), no NPDRM |
| Imports | **done** — 229 across 18 libraries, 204 named (89%) |
| Function discovery | **done** — 28,162 found, 27,137 `.opd` descriptors as ground truth |
| PPU lift | **done** — 28,987 functions, 6 chunks, 193 MB of C++, 6 continuation warnings |
| Build & link | **done** — first attempt, 13/13, **nothing title-specific in the tree** |
| Boot | **runs** — 17 system modules, `cellGame` check passes, `sceNp` init, window open, 22–57 fps |
| Assets | **not loaded** — see below |

## Where it stops

It reads its asset table-of-contents correctly and then stops opening files:

```
[fs] open '/dev_bdvd/PS3_GAME/USRDIR/DATA//COMPRESSED/PS3/COMPRESS.TOC.PS3' -> fd 3
[fs] read fd=3 nbytes=14336 -> 14336 (magic=544F4331, total=14336)   <- "TOC1", full read
[fs] open FAIL '/dev_bdvd/PS3_GAME/USRDIR/DATA/SCRIPTS/ENGINE/ENGINE_PARAMS.QB.PS3'
```

**Two opens in a whole run, and no third.** The failed one is expected — the
scripts live in `COMPRESSED/PS3/PAK/QB.PAK.PS3` + `QB.PAB.PS3`, and Neversoft
probes the loose path first — but the fall-back to the PAK never happens. The
disc has 591 PAKs (1.1 GB) that are never touched.

Meanwhile the title is alive and cycling, not deadlocked. A syscall trace shows
exactly one syscall, `141` (`sys_timer_usleep`), and the watchdog names
consecutive samples as `sys_spinlock_unlock` then `sys_spinlock_lock` — a
worker loop waiting on something, spinning at ~50 fps with 0 draw packets.

**So the open question is what that loop is waiting for between reading the TOC
and loading the first PAK.** It is not a missing file, not a wrong error code
(`CELL_FS_ENOENT` is correct), and not a dead thread.

### One trap already cleared

The watchdog originally reported this wedge as **`cellPadInit`**, which for a
game that cannot start without a guitar controller is a very convincing wrong
answer. It was a runtime bug: the `g_ctx[]` dispatch path — the whole
sysPrxForUser/CRT surface — never recorded the handler name, so the watchdog
printed whichever *table* handler ran last. Fixed upstream; it now says
`sys_spinlock_unlock`.

## Building

```bash
./tools/relift.sh                     # imports.json, functions.json, lifted tree, NID table
cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
cmake --build build
PS3_VFS_ROOT=vfs RSX_LIVE_DRAW=1 ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf
```

`--code-end 0x9B3F38` in `relift.sh` is load-bearing: it sits just past the
`.lib.stub` import trampolines (`0x9B2298..0x9B3F38`) so `--hle-stubs` has
something to rewrite, and no further, because everything above is `.rodata` in
the same R-X segment — the data-as-code trap that cost flOw and YDKJ
multi-gigabyte lifts.

## Legal

No game code, assets or keys here — only analysis and build configuration.
Supply your own legally dumped disc.
