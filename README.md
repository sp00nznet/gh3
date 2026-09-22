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

Everything is running — PPU, SPU and RSX — and every frame is still black.

| | |
|---|---|
| Files opened | **14, zero failures** |
| SPU | **both images dispatch by fingerprint and run** (`image=4`, `image=5`) |
| Draw groups | **3,226 executed, 0 dropped**, 3,069 `draw_arrays` in the FIFO |
| Guest clears | 6,455 |
| Textures created | **0** |

Assets it loads: `COMPRESS.TOC`, `ENGINE_PARAMS.QB`, `QB.PAK`+`QB.PAB`, the
material library, `BOOT_LEGAL.IMG`+`.IMV`, `LOAD_WHEEL.IMG`+`.IMV`, animation
data, `CUTSCENE_INFOS.PAK`, `GLOBAL_AD_TEX.PAK`+`_VRAM`.

### The frontier: a sampled surface nothing draws into

Not one real texture is ever created — `binds[white=0 real=0 surf=3226]`, every
single bind resolves to a render surface. The obvious conclusion is that the
alias test is too loose, and it is wrong. With the alias **hit** reported
(added upstream for this):

```
[alias-hit] tex 0:0x00200000 fmt=0xA5 1040x592 -> surface[1] 0:0x00200000 1040x592
```

Same location, same offset, same dimensions — a deliberate render-to-texture
pass. The bind is correct. `LD_SURF_DUMP` then says what is actually wrong:

```
[surf-dump] slot=0 0:0x00000000 1280x720 nonblack=0 draw_gen=0    clear_gen=0
[surf-dump] slot=1 0:0x00200000 1040x592 nonblack=0 draw_gen=0    clear_gen=3794
[surf-dump] slot=2 0:0x00510000 1280x720 nonblack=0 draw_gen=3796 clear_gen=3795
[surf-dump] slot=3 0:0x00894000 1280x720 nonblack=0 draw_gen=3793 clear_gen=3792
```

**Slot 1 — the surface every draw samples — is cleared 3,794 times and has
`draw_gen=0`: nothing ever renders into it.** Slots 2 and 3 *are* drawn into,
but they sample slot 1, so they render black, and the screen stays black.

So the question is narrow: what should be filling surface 1 (1040x592 at
0x200000), and why does that pass never issue a draw. Ruled out already — it is
not a 2D/NV3089 blit (no 2D engine traffic at all), not a dropped command (0
dropped groups, and the unknown methods are one-off state), and not the SPU
(both tasks dispatch and run).

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
