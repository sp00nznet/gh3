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
| Frontend | **not reached** — one failed allocation, then a memset over the TOC; see below |

## Where it stops: one failed allocation, then a memset over the TOC

The stall is not in the decompressor's SPU job. It is a `memset(NULL, 0, ~10MB)`
that the decompressor path makes on the main thread, and what that memset
destroys.

`func_0041DB10` asks its allocator for 0x14 bytes, gets 0 back, and the caller
memsets the buffer without checking. The sweep runs UP from address 0. On real
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

### The open question: a count that is really the TOC

The allocation does not fail spuriously -- it is refused honestly, because the
request is enormous. `func_006479BC(descriptor, count)` takes the element count
in r4, and at the failure it is `r31 = 0x01490752`:

```
r31        = 0x01490752
r31 << 3   = 0x0A483A90   the allocation size   -> 164 MB, refused
r31 << 2   = 0x05241D48   the memset length     ->  82 MB, over a null pointer
TOC        = 0x00A483A8
r31 == (TOC + 1) * 2      exactly
```

That is not a plausible count; it is the TOC pointer with arithmetic on it. The
same `0x05241D48` shows up as the bogus "OPD" in the `[null-call]` reports, so
the one bad word propagates. r31 is `func_006479BC`'s *second argument*, so the
garbage is computed by its caller -- that caller is the next thing to find.

A TOC-valued word turning up where a count belongs is the signature to chase:
the lifter rewrites `ld r2,N(r1)` after an indirect call into a hardcoded
`ctx->gpr[2] = 0x00A483A8` (`TOCFIX`), so a misidentified `ld rX,N(r1)` would
put the TOC in the wrong register. Worth ruling in or out first.

### Heap selection works; the null heap is a red herring

`func_006479BC` picks a heap by comparing r13 against a table of registered
thread pointers at `[[TOC+0x3734] - 0x8000]`, falling back to a default slot.
Measured: tid=1, 7 and 8 each register and get heaps A/B/C
(`0x107BC2E0/E4/E8` <- `0x110BDAF0`, `0xD00B5C90`, `0xD00F6BE0`), all long
before the failure and never zeroed. The DEFAULT slot `0x107BC2EC` is never
written -- by design, not a bug. The main thread matches heap A and gets it.

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
