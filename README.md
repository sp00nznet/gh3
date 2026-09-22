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

## Status: renders its loading screen; stops before the frontend

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
| Frontend | **not reached** — blocked on SPU decompression, see below |

## Where it stops: a SPU decompression job that never completes

Every asset on this disc lives under `DATA/COMPRESSED/`, and `func_004BF614`
is the engine's decompressor. Its own format strings name its three paths:

```
'Decompress Data (%p | %p) using Job (SPU)'            async
'Decompress Data (%p | %p) using Blocking Job (SPU)'   <-- the main thread sits here
'Decompress Data (%p | %p) Blocking Direct (PPU)'      fallback
```

The main thread submits a blocking SPU decompression job and waits for it
**187,251 times per minute** and forever. Nothing else can proceed, so the
loader never queues the 15th file and the loading record spins.

Proof, not inference: `func_0001A134()` selects between the blocking-SPU and
direct-PPU paths, and it is a one-line getter reading a global. Pinning that
global to 0 with `PPU_FORCE_READ_ADDR=102001A4 PPU_FORCE_READ_VAL=0` sends the
engine down its own PPU path, and the boot **advances a whole stage**: 14 -> 17
files, loading `ZONES/GLOBAL.PAK` + `.PAB` + `_VRAM.PAK` — 24 MB of zone data,
every read complete and matching the disc byte for byte.

That is a diagnostic, **not a workaround**: four other functions read the same
global, and with it pinned the run takes 12.7 million NULL dereferences
(`[null-read] ... by guest-fn=0x001C3A74`, 1 without it). It proves what the
blocker is; it does not fix it.

### Why the SPU side does nothing

GH3 runs two SPURS tasksets. Both dispatch and both run — and task 0 wakes on
every signal and **runs 0 ms**, thousands of times:

```
[spu_workload] signal task 0 (taskset ...)
[spu_workload] WAIT_SIGNAL#9500 enter task=0 taskset=... ran=0ms
[spu] SPURS taskset syscall num=2 ... image=4
```

Five SPU images are lifted and registered. Only **images 4 and 5 ever dispatch**
— the two taskset contexts. Images 1-3, which are the task bodies, never run at
all. So what executes is the taskset shell cycling WAIT_SIGNAL, never the task's
own ELF, and the decompressor inside it is never reached. That is the same SPU
middleware gap that has Virtua Fighter 5, Tokyo Jungle and YDKJ stuck, and it is
the next thread to pull.

How the stall was found, since three earlier guesses were wrong: `PS3_POLLTOP`
(added upstream for this) histograms `sys_timer_usleep` callers **by thread**.
Without the thread id the async-FS thread's idle wait looked like the stall, and
pinning the flag it waits on changed nothing. With it, tid=4/3/5/9 are the
renderer, async FS, Bink and FMOD idling by design, and tid=1 is parked on one
site — `func_004BF614+0x2DC`, the decompression wait.

### The black screen was an unimplemented RSX method

Every frame was black, and every symptom pointed at the render target:

```
[surf-dump] slot=1 0:0x00200000 1040x592 nonblack=0 draw_gen=0    clear_gen=3794
```

The surface every draw samples — through a *legitimate* render-to-texture
alias, `[alias-hit] tex 0:0x00200000 -> surface[1]`, same location, offset and
dimensions — was cleared 3,794 times and never drawn into. Zero textures were
ever created: `binds[white=0 real=0 surf=3226]`. Ruled out along the way: not a
2D/NV3089 blit (no 2D traffic), not a dropped command (0 drops), not the SPU
(both images dispatch and run), not an SPU-built pushbuffer (the FIFO walker is
caught up every drain, `getoff == put`).

The answer was in the method stream. A histogram of 120,000 steady-state RSX
methods put **`0x1818` on top with 9,388 occurrences**, alongside 503
`BEGIN_END(prim=8)` pairs and only 168 `DRAW_ARRAYS`. `0x1818` is
`NV4097_INLINE_ARRAY` — vertices pushed through the FIFO instead of fetched
from a vertex array — **and nothing in ps3recomp consumed it**. Every draw in
GH3's 2D layer arrived carrying no vertices and was counted as an empty group.

The layout is derivable because the hardware packs the *enabled* attributes in
ascending register order at the declared stride; GH3's decodes as attr0 F32[4]
+ attr3 UB[4] + attr8 F32[2] = 28 bytes, exactly its VTXFMT stride, and reads
out as screen-space quads with white vertex colour and 0..1 UVs.

Fixed upstream (`750bb09`). Measured here:

| | before | after |
|---|---|---|
| Groups executed | 4,548 | **14,669** |
| Empty groups | 9,091 | **0** |
| Real texture binds | 0 | **4,887** |
| Scene surface | `draw_gen=0 nonblack=0` | `draw_gen=5297` **`nonblack=1601`** |

Two things were needed to get there, and the first alone was not enough: the
dispatcher had to deliver the stream, *and* the shared vertex fetch plan had to
read from it. Wiring only the live engine's legacy mode left the default
(compact) mode reading whatever the last ordinary draw had left in the array
offsets — the draws executed and still put nothing on screen.

The one texture GH3 binds is a 128x128 DXT5 whose colour endpoints are all
zero and whose alpha block is real: a black overlay with an alpha mask. It
renders black *correctly*. `LD_TEXSRC_DBG` (added upstream for this) is what
settled that, by reporting source bytes for compressed formats the decoded-RGBA
dump never reached.

### The hang that was here, and what it actually was

The port previously wedged with **48 million iterations** in a loop, pinning a
core, and the chain is worth recording because almost none of it was the port's
fault:

```
func_0026334C     formats "scripts\engine\engine_params.qb.ps3"
  func_00263014   resource get-or-create
    func_004D0820 FILE LOAD -> returns NULL   (the file was not on disc)
  func_00270F60   passes that NULL on as a container
    func_00264134 iterates it:
                    end = obj + obj->size;  cur = obj + 0x1C;
                    while (end != cur) cur = step(cur);
```

With `obj == NULL`, `obj->size` reads as 0, so `end` is 0 while `cur` starts at
0x1C, and an **equality**-terminated loop that can never be equal runs forever.

**The root cause was a truncated disc extraction**, not the recompilation: 1,004
of 2,910 files were missing, including `ENGINE_PARAMS.QB.PS3`, because a
background extract was still running when the tree was moved. Re-extracting
fixed the hang outright — 1 failed open became 0, and the title went from 2 file
opens to 14.

Two things are worth keeping from it anyway. On real hardware that NULL
dereference is a data-storage exception and the title dies instantly holding the
pointer; our flat VM reads address 0 as zero, so a fatal bug degrades into a
silent hang. ps3recomp now reports NULL reads (`[null-read]`) and names the
chain in one run, where cornering it by hand took six probe-and-rebuild cycles.
And **verify the extraction before blaming the port** — this is the second port
in a row (after Virtua Fighter 5) whose "bug" was the data on disk.

### Two diagnostics lied on the way, both fixed upstream

* The watchdog reported the wedge as **`cellPadInit`** — for a game that cannot
  start without a guitar controller, a very convincing wrong answer. It never
  recorded names for `ps3_hle_register_ctx` handlers (the whole sysPrxForUser
  surface), so it printed whichever *table* handler ran last.
* A host-stack backtrace through lifted code produced a confident five-frame
  call chain that direct call counters proved was **fiction** — every function
  in it runs exactly once. The lifted TU has no unwind tables, which the
  sampling profiler already documents; `ctx->lr` is the chain to trust.

Also added upstream and used here: a stuck-spinlock detector that names the
holding thread and flags self-deadlock. Its *silence* is what ruled the
spinlocks out.

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
