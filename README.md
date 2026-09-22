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

### The hang, root-caused

The main thread pins a core and never loads an asset. Traced end to end:

```
func_0026334C        builds a name on the stack, then
  func_00263014      LOOKS SOMETHING UP  ->  returns NULL        <-- the bug
  func_00270F60      passes that NULL straight on as a container
    func_00264134    iterates it:
                         end = obj + obj->size;   cur = obj + 0x1C;
                         while (end != cur) cur = step(cur);
```

With `obj == NULL`, `obj->size` reads as **0**, so `end` is 0 while `cur`
starts at 0x1C. The loop terminates on **equality**, which can now never
happen — so it runs **48 million iterations** in 70 seconds, climbing through
2.8 GB of address space, allocating and freeing a ~20-byte node each time.

On real hardware this never gets that far: the PS3 leaves the first 64 KB
unmapped, so `obj->size` through a NULL pointer is a data-storage exception and
the title dies on the spot holding the pointer. Our VM is flat and
demand-committed, so address 0 reads back as zero and the fault degrades into a
silent infinite loop. ps3recomp now reports it (`[null-read]`, added for this),
which names the chain in one run — it took six probe-and-rebuild cycles by hand.

**So the open question is narrow: why does `func_00263014` return NULL?** It is
handed a freshly formatted string and returns a pointer, and it fails on the
very first call — which lines up with the title never opening a PAK.

### What has been ruled out

Most of the obvious suspects are eliminated, which is the useful part:

* **Not the async filesystem.** The 1 ms `sys_timer_usleep` loop that dominates
  a syscall trace is `CAsyncFileSys::sThreadUpdate` (guest tid 3, entry
  `0x00A257A0`) running its **service loop correctly** — it pumps, sleeps 1 ms,
  and spins only while a quit flag at `0x106A5B48` stays zero. That is the
  thread working, not hanging, and I mistook it for the stall first time round.
* **Not a stuck spinlock.** The `sys_spinlock_lock`/`unlock` storm is GH3's own
  allocator being hot. ps3recomp's stuck-lock detector (added for this) never
  fires, which is what ruled it out.
* **Not a missing file or a wrong error code.** `CELL_FS_ENOENT` is correct and
  the file genuinely is not on disc.
* **Not SPURS.** There is no SPURS activity at all yet, so the empty
  `src/spu_gen/` is not the cause.
* **Not a dead thread.** Both guest threads start and run.

**Two diagnostics lied on the way, both now fixed upstream.** The watchdog
reported the wedge as `cellPadInit` (it never recorded names for
`ps3_hle_register_ctx` handlers, so it printed whichever *table* handler ran
last) — for a game that needs a guitar controller, a very convincing wrong
answer. And a host-stack backtrace through lifted code produced a confident
five-frame call chain that direct call counters proved was **fiction**: every
function in it is called exactly once. The lifted TU has no unwind tables, which
the sampling profiler already documents; `ctx->lr` is the trustworthy chain.

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
