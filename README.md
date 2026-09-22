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
| Frontend | **not reached** — a `this` that is really a vtable; slot 6 becomes a hash table, the rehash asks 164 MB, fails, memsets 82 MB over the image |

## Where it stops: a `this` that is really a vtable, during startup init

The stall is not in the decompressor's SPU job. It is a `memset(NULL, 0, ~10MB)`
that the decompressor path makes on the main thread, and what that memset
destroys.

The engine's array allocator gets 0 back from the heap and memsets the null
buffer without checking. The arguments, read off the failing call:

```
memset(dst = 0x00000000, c = 0, len = 0x05241D48)    82 MB, over a null pointer
```

The sweep runs UP from address 0. On real
hardware the first store faults; here the whole 32-bit guest space is backed, so
it runs silently through the unused copy of the code image and then straight
through this title's data segment at `0x009D0000` -- which holds `.data`, `.opd`
**and the TOC** (`0x00A483A8` is inside `ph1` = `0x009D0000..0x00A4E130`).

Verified both ways: the ELF has `{0x004AFCAC, 0x00A483A8}` at `0x00A24868`, a
perfectly good function descriptor; the running guest reads all zeros there.

After that every TOC-relative global in the game reads 0. That is the source of
every other symptom, and each of them cost a session of its own before this was
found:

| symptom | actually |
|---|---|
| ~20 million `[null-read]` per boot from `func_00261F54` | it walks a table whose TOC base was zeroed |
| four allocator pool globals `0x104306E4/E8/EC/F0` null | never written *and* the pool feature is off by config |
| vtable dispatch to address 0 in `func_00649694`, `func_00663B84` | their TOC-resident objects were zeroed |

`runtime/ppu/ppu_loader.cpp` now reports and DROPS a guest store into the first
page (`[null-write]`, `PS3_NULL_WRITE=0` to disable), so this class of failure
announces itself instead of presenting as five unrelated bugs in five
subsystems.

### What is NOT wrong (measured, so it does not get re-derived)

- The per-thread allocator stack works. `func_004B4908` returns `r13-0x6FF8`,
  the stack top lives at TLS+0x4C, `func_004D6A60`/`func_004D6BD8` push and pop.
  A watch on the main thread's real TLS block shows depth 1/2/3 with real
  allocator objects (`0x106A6C88`, `0x110010D0`).
- The global allocator singleton `0x106A6BF0` is constructed (`<- 0x106A6DE8`).
- `func_00267BEC` (which allocates four memory pools) early-outs on a byte at
  `0x10683F82` -- but that byte is a parsed config option `func_004B98DC`
  deliberately sets to 0. Off by design in a retail build.
- The guest heap syscalls are fine; lv2 hands out `0x40000000+`.

**Watch the right TLS block.** GH3's main thread runs on `r13 = 0x0E007000`,
from `sys_initialize_tls` -- not `PPU_TLS_TP` (`0x10F07000`). Four write watches
aimed at the wrong block all read as "nothing ever writes this", which is how
the allocator stack got blamed. `[GSTACK]` now prints `r13` and `tid`.

### Where it is called from

A back-chain walk (`[GSTACK] chain:`, ELFv1: back chain at `[sp]`, lr at
`back_chain+0x10`) gives the real callers, ending at the CRT entry:

```
memset <- func_0023EE10+0x8C <- func_0005AC94+0x64 <- func_0005BFC0+0xD0 (x2)
       <- func_00064288+0xC0 <- func_00069DFC+0xAE8 <- func_0006AC90+0x1D0
       <- func_0006B654+0x3A8 <- func_002898C4+0x3DC <- func_002877CC+0xD0
       <- func_0028BB14+0x18C <- func_00526AB4+0x4F8 <- func_00113BB4+0x100 (x4)
       <- func_005229A4+0xD80 <- func_00010250+0x154 <- func_00010244+0x8
```

**This is startup init, not decompression.** `func_005229A4` is the same init
function that calls the memory-pool setup. Earlier notes here blamed
`func_004BF614` (the decompressor) -- that came from the stack SCAN, which
reports any stack word that looks like a return address including dead slots
from frames that already returned. The scan named `func_0041DB10`,
`func_003F8EA0` and `func_004BF614`; none of them are in the real chain. Trust
`chain:`, not `sp=...:`.

Note the walk prints RETURN addresses, so it never names the innermost frame --
the function that actually made the failing call is the one missing from the
top of that list.

### Root cause: a `this` pointer that is actually a vtable pointer

`func_006637AC` is entered with `r3 = 0x101047A0`. That address is a **vtable**
-- all twelve slots inspected are `.opd` pointers:

```
0x101047A0 +0x00 00A331D0  +0x04 00A331B0  +0x08 00A0FE00  +0x0C 00A33130
           +0x10 00A33138  +0x14 00A33198  +0x18 00A331A0  +0x1C 00A33140
           +0x20 00A33148  +0x24 00A331A8  +0x28 00A33190  +0x2C 00A32FB0
```

It keeps that value in r25 and later does
`table = [r25 + 0x18] + 0xC` -- reading **vtable slot 6**, a function
descriptor address, and using it as an object. Everything after that is
mechanical:

```
[r25+0x18]   = 0x00A331A0   vtable slot 6 = OPD for code 0x0074DAB0
table        = 0x00A331AC   = that OPD + 0xC, i.e. inside .opd
[table+4]    = 0x0074DAE8   the NEXT descriptor's code, read as the load
[table+8]    = 0x00A483A8   the NEXT descriptor's TOC,  read as the capacity
cap*2 + 2    = 0x01490752   the rehash count            -> 164 MB, refused
count << 2   = 0x05241D48   the memset length, measured ->  82 MB, over NULL
```

Every value verified against the raw ELF bytes.

**So the whole boot failure is one bad `this`**: somewhere up the chain an
object pointer is dereferenced once too many, and `*(obj)` is an object's
vtable. `r25` is simply `func_006637AC`'s first argument, and its caller
`func_00663B84` passes its own `r3` straight through, so the bad pointer comes
from further up. Walking that `this` provenance is the next step.

Handy: `[GSTACK]` now prints the whole GPR file, so one run gives every
register rather than whichever two were guessed in advance. `PPU_RWATCH` dumps
the chain and registers on its first hit, which is how r25 was caught.

### Heap selection works; the null heap is a red herring

Heaps are picked by matching r13 against a table of registered thread pointers
at `[[TOC+0x3734] - 0x8000]`. Measured: tids 1, 7 and 8 each register and get
heaps A/B/C (`0x107BC2E0/E4/E8` <- `0x110BDAF0`, `0xD00B5C90`, `0xD00F6BE0`),
long before the failure and never zeroed. The DEFAULT slot `0x107BC2EC` is never
written -- by design.

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
