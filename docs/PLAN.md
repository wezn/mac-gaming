# mac-gaming: a CrossOver-style Windows game runner for macOS

## What CrossOver actually is

CrossOver (CodeWeavers) is not a from-scratch emulator. It is a curated stack:

| Layer | What it does | Source |
|---|---|---|
| **Wine** (CrossOver 26 = Wine 11) | Reimplements the Win32/NT APIs so `.exe` files run natively as macOS processes | LGPL, CodeWeavers publishes their patched tree |
| **Rosetta 2** | Translates x86-64 machine code to ARM64 on Apple Silicon | Apple, built into macOS |
| **msync** | Fast Windows sync primitives (events/mutexes) on Mach semaphores; a large CPU win in multithreaded games | Open source (in CrossOver/Gcenx/Whisky trees) |
| **D3DMetal** | DirectX 11/12 → Metal | Apple Game Porting Toolkit (closed, restrictive license) |
| **DXMT** | DirectX 10/11 → Metal | Open source (3Shain/dxmt) |
| **DXVK + MoltenVK** | DirectX 9/10/11 → Vulkan → Metal | Open source |
| **wined3d** | DirectX 1–9 → OpenGL/Vulkan | Part of Wine |
| **wine-mono / wine-gecko** | .NET and HTML engine replacements | Open source |
| **Bottle manager GUI** | Per-game prefixes, installers, per-game config | CodeWeavers' proprietary part |

Rewriting Wine itself would take decades of work and would not be faster. Wine is
already a native reimplementation, not an emulator. Almost all overhead comes from
x86→ARM translation (Rosetta) and graphics API translation. Those are the layers to
pick carefully.

## Fastest-path architecture

1. **Wine 11, WoW64 build** (a single 64-bit Unix side that also runs 32-bit games).
   Build from CodeWeavers' published CrossOver source to get their macOS fixes.
2. **Rosetta 2** for x86 game code. No open alternative on macOS comes close.
3. **msync enabled by default.**
4. **Per-game graphics backend auto-selection:**
   - DX12 → D3DMetal (the only mature option)
   - DX11 → DXMT first (often fastest, especially on base M-series), falling back to D3DMetal and then DXVK+MoltenVK
   - DX10 → DXMT
   - DX9 and older → DXVK (d3d9) via MoltenVK, or wined3d
5. **Retina/high-res mode**, plus optional MetalFX upscaling where D3DMetal exposes it.
6. **Native launcher app** (Swift/SwiftUI): bottles, Steam installer, per-game profiles,
   FPS/perf HUD, logs.

## Constraints

- **D3DMetal license**: Apple allows only *non-commercial* redistribution. Personal or
  free use is fine. A paid product would need the user to supply GPTK themselves.
- **Kernel anti-cheat** games (Valorant, many BattlEye/EAC titles) will not run.
  CrossOver has the same limit.
- **Build environment**: Wine for macOS has to be built on macOS with Xcode (or on
  GitHub Actions macOS runners). It cannot be built or tested from Linux.

## Milestones

1. CI build of Wine (CrossOver source) + msync on macOS runners → `.tar.xz` artifact
2. Integrate DXMT, DXVK+MoltenVK, optional D3DMetal; CLI `mgx run game.exe --backend=auto`
3. Bottle management + Steam bootstrap
4. SwiftUI launcher app, signed `.app`
5. Per-game profiles DB + benchmarking harness (frame-time capture per backend)

## Selling it: licensing

| Component | License | OK to sell? |
|---|---|---|
| Wine / CrossOver source | LGPL-2.1+ | Yes. You must publish the source of any changes you make to Wine (CodeWeavers does this) |
| DXMT (v0.80, `dxmt-*.tar.xz`) | MIT (checked at v0.80; LICENSE ships in the artifact) | Yes, with attribution |
| LLVM 15 (statically linked into DXMT's `winemetal.so`) | Apache-2.0 with LLVM exception | Yes. The LLVM exception waives attribution for compiled binaries; crediting it anyway is good form |
| GCC runtime and mingw-w64 runtime (statically linked into DXVK's DLLs: libstdc++, libgcc, winpthreads; DXMT's DLLs use llvm-mingw's libc++/libunwind instead) | GPL-3.0 + GCC Runtime Library Exception; libc++ Apache-2.0 with LLVM exception; mingw-w64 runtime ZPL-2.1 and others; winpthreads MIT/BSD-style | Yes. The exception permits proprietary distribution; keep the mingw-w64 and winpthreads notices |
| FreeType, GnuTLS (in the Wine runtime's `lib/`) | FTL (chosen over GPL-2.0); LGPL-2.1+ | Yes, with the FreeType credit; GnuTLS ships as a replaceable dylib |
| GMP, Nettle (GnuTLS dependencies, in `lib/`) | LGPL-3.0+ (chosen over GPL-2.0+) | Yes, as replaceable dylibs with source offered |
| Libraries Wine bundles (libpng, libjpeg, zlib, FAudio, vkd3d, OpenLDAP, ...) | permissive or LGPL-2.1+ | Yes, with their notices |
| DXVK-macOS (Gcenx fork, v1.10.3-20230507-repack, `dxvk-macos-*.tar.xz`) | zlib (LICENSE ships in the artifact) | Yes |
| MoltenVK | Apache-2.0 | Yes, with attribution |
| D3DMetal (Apple GPTK) | Apple license, **non-commercial redistribution only** | **No, not without an agreement with Apple.** Options: ask Apple for a commercial license, or have users install GPTK themselves and point the app at it |

That makes D3DMetal the main business risk. It is the only mature DirectX 12 path and
the default backend for Overwatch 2. To own a sellable fast path, invest in DXMT
(contribute upstream, or sponsor it).

Full notices for everything shipped (including the libraries bundled in the Wine runtime):
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Releases attach the CrossOver and Nettle source
tarballs for the LGPL parts ([RELEASING.md](RELEASING.md)).

For now the app is sold ad-hoc signed (users approve it once with Open Anyway, see
[INSTALL.md](INSTALL.md)). Later it needs an Apple Developer ID ($99/yr) and notarization. It cannot use
"Wine" or "CrossOver" in its name (trademarks).

## Target games

- **Overwatch 2** (DX11, Battle.net): CodeWeavers rates it "Runs Well" on CrossOver
  26.3, using D3DMetal. Benchmark DXMT against it. Game updates have broken it before.
- **Counter-Strike 2** (DX11/Vulkan, VAC): runs under CrossOver, but VAC ban risk in
  matchmaking is unclear. Third-party reports exist but are unverified. Test only on a
  throwaway account.
