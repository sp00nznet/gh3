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

It gets to **`cellGcmInit`** and then stops making forward progress. The last
HLE call of the boot is

```
[HLE] _cellGcmInitBody(ctx_out=0x1081D2F0, cmdSize=0x10000, ioSize=0x200000, ioAddr=0x40100000)
```

and nothing graphics-related follows it: no display buffers, no flip, zero draw
packets reaching the engine.

It reads its asset table-of-contents correctly on the way:

```
[fs] open '/dev_bdvd/PS3_GAME/USRDIR/DATA//COMPRESSED/PS3/COMPRESS.TOC.PS3' -> fd 3
[fs] read fd=3 nbytes=14336 -> 14336 (magic=544F4331, total=14336)   <- "TOC1", full read
[fs] open FAIL '/dev_bdvd/PS3_GAME/USRDIR/DATA/SCRIPTS/ENGINE/ENGINE_PARAMS.QB.PS3'
```

**Two opens in a whole run and no third.** The failed one is expected — the
scripts live in `COMPRESSED/PS3/PAK/QB.PAK.PS3` + `QB.PAB.PS3` and Neversoft
probes the loose path first — but the 591 PAKs (1.1 GB) are never touched.

### What has been ruled out

Most of the obvious suspects are eliminated, which is the useful part:

* **Not the async filesystem.** The 1 ms `sys_timer_usleep` loop that dominates
  a syscall trace is `CAsyncFileSys::sThreadUpdate` (guest tid 3, entry
  `0x00A257A0`) running its **service loop correctly** — it pumps, sleeps 1 ms,
  and spins only while a quit flag at `0x106A5B48` stays zero. That is the
  thread working, not hanging, and I mistook it for the stall first time round.
* **Not a missing file or a wrong error code.** `CELL_FS_ENOENT` is correct and
  the file genuinely is not on disc.
* **Not SPURS.** There is no SPURS activity at all yet — the title never gets
  as far as submitting SPU work, so the empty `src/spu_gen/` is not the cause.
* **Not a dead thread.** Both guest threads (`NetThreadUpdate`,
  `CAsyncFileSys::sThreadUpdate`) start and run.

**What the main thread is doing:** its own heap allocator. The HLE tail is
`sys_mmapper_allocate_memory` → `sys_mmapper_map_memory` → `sys_lwmutex_lock`
and then `sys_spinlock_lock`/`unlock` pairs forever — that pairing is GH3's
spinlock-protected allocator, hot rather than wedged.

So the open question is why, having initialised GCM and its heap, the main
thread never queues the first PAK read through the async filesystem that is
sitting there idle waiting for work.

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
