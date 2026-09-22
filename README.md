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
| Frontend | **not reached** — see below |

## Where it stops

The boot assets all load and the 2D layer renders. The title sits on its
loading screen forever: **14 file opens at 120s and still 14 at 300s**, with
the loading record spinning the whole time. Nothing is blocked — no syscall
blocks for 150ms, no `sys_event_queue_receive` blocks at all; six threads
poll on `sys_timer_usleep` because that is how the engine is built
(`PS3_POLLTOP` upstream names the sites: frame limiter, async-FS pump, flip
wait). The async-FS pump is idle in the steady state, so the game is not
waiting on a load — **it never queues the next one**.

So the remaining work is the boot state machine / QB script VM, not graphics.

Assets it loads: `COMPRESS.TOC`, `ENGINE_PARAMS.QB`, `QB.PAK`+`QB.PAB`, the
material library, `BOOT_LEGAL.IMG`+`.IMV`, `LOAD_WHEEL.IMG`+`.IMV`, animation
data, `CUTSCENE_INFOS.PAK`, `GLOBAL_AD_TEX.PAK`+`_VRAM`.

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
