# Build artifacts

Every artifact is a `.tar.xz` with one top-level directory, uploaded as a GitHub Actions
artifact (GitHub wraps it in a `.zip` on download). Paths below are relative to the tarball.

| Artifact | Workflow | Built by | Pinned source |
|---|---|---|---|
| `wine-crossover-<cx>-wow64.tar.xz` | `build-wine.yml` (and `build-graphics.yml`, job `wine`) | `scripts/build-wine.sh` | CodeWeavers CrossOver sources `<cx>` (default 26.3.0) |
| `wine-crossover-<cx>-wow64-devel.tar.xz` | `build-graphics.yml`, job `wine` (artifact `wine-sdk`, kept 3 days) | `WINE_DEVEL=1 scripts/build-wine.sh` | same |
| `dxmt-<version>.tar.xz` | `build-graphics.yml` | `scripts/build-dxmt.sh` | [3Shain/dxmt](https://github.com/3Shain/dxmt) `v0.80` = `589adb780354b461645b29999cefaf533594ee99` |
| `dxvk-macos-<version>.tar.xz` | `build-graphics.yml` | `scripts/build-dxvk.sh` | [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) `v1.10.3-20230507-repack` = `8f1e28deed3ad30802f7e1bdff428ec14e6e7817` |

To bump a graphics layer, change the `*_TAG` / `*_COMMIT` pair at the top of its script.
The script refuses to build if the tag no longer points at the pinned commit.

## `wine-crossover-<cx>-wow64.tar.xz`

```
wine/
  bin/wine, bin/wineserver, ...
  lib/libMoltenVK.dylib, lib/libfreetype*.dylib     # x86_64 deps, found via @rpath
  lib/wine/x86_64-windows/*.dll, *.exe, *.drv ...    # 64-bit PE builtins
  lib/wine/i386-windows/*.dll ...                    # 32-bit PE builtins (WoW64)
  lib/wine/x86_64-unix/*.so                          # Unix side (Mach-O x86_64, runs under Rosetta 2)
  share/wine/...
```

WoW64 build: there is a single `bin/wine` (no `wine64`), and it runs both 64- and 32-bit
programs. Wine's Vulkan driver (`winevulkan`) loads the bundled `lib/libMoltenVK.dylib`.

## `wine-crossover-<cx>-wow64-devel.tar.xz`

The output of `make install-dev`, laid out to be extracted **over** the runtime tree:

```
wine/
  bin/winebuild, winegcc, widl, wrc, ...             # x86_64 Mach-O, run under Rosetta 2
  include/wine/...                                   # Wine/Windows headers
  lib/wine/{x86_64,i386}-windows/lib*.a              # PE import libs (libntdll.a, libwinecrt0.a, ...)
```

Only needed to build against this Wine (DXMT uses it). Launchers ship the runtime tarball.

## `dxmt-<version>.tar.xz` (Direct3D 10/11 → Metal)

```
dxmt/
  x86_64-windows/d3d11.dll dxgi.dll d3d10core.dll winemetal.dll   # 64-bit PE
  i386-windows/d3d11.dll dxgi.dll d3d10core.dll winemetal.dll     # 32-bit PE
  x86_64-unix/winemetal.so                                        # Unix side, Mach-O x86_64
  LICENSE                                                         # MIT, ship it (attribution)
  VERSION                                                         # tag, commit, Wine it was built against
  dxmt.conf                                                       # sample config (DXMT_CONFIG_FILE)
```

DXMT is built with `-Dwine_builtin_dll=true` (DXMT's default for its CI artifacts): the PE
DLLs are stamped as Wine builtins by our `winebuild`, and `winemetal.so` is linked against our
`ntdll.so` / `winemac.so`. **Use it with the Wine build of the same `<cx>` version it was
built against** (`VERSION` records it). It is not a drop-in for other Wine builds.

There is no separate 32-bit `winemetal.so`: under WoW64, the 32-bit DLLs thunk into the one
x86_64 unixlib. Only `x86_64-unix/` exists.

### Installing DXMT

DXMT replaces Wine's own `d3d11`/`dxgi`/`d3d10core` builtins, so it is installed into a copy
of the Wine tree used for DXMT games (or the launcher's Wine tree, if every bottle uses DXMT):

| File | Goes to |
|---|---|
| `dxmt/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll` | `<wine>/lib/wine/x86_64-windows/` (overwrite) |
| `dxmt/i386-windows/{d3d11,dxgi,d3d10core,winemetal}.dll` | `<wine>/lib/wine/i386-windows/` (overwrite) |
| `dxmt/x86_64-unix/winemetal.so` | `<wine>/lib/wine/x86_64-unix/winemetal.so` |
| `dxmt/x86_64-windows/winemetal.dll` | `<prefix>/drive_c/windows/system32/winemetal.dll` |
| `dxmt/i386-windows/winemetal.dll` | `<prefix>/drive_c/windows/syswow64/winemetal.dll` |

Then:

- **DLL overrides: none.** The DLLs must load as *builtin*. Do **not** set
  `d3d11`/`dxgi`/`d3d10core` to `native` / `n,b` in `WINEDLLOVERRIDES` or the registry,
  and remove any DXVK overrides from the bottle.
- `winemetal.dll` is not in Wine's own list of system DLLs, so `wineboot` does not copy it
  into the prefix; copy it yourself, after `wineboot` has created the prefix. (Prefixes created
  *after* the Wine tree was patched already get DXMT's `d3d11`/`dxgi`/`d3d10core` in
  `system32`/`syswow64`; for an older prefix, run `wineboot -u` once.)
- `winemetal.so` must sit next to Wine's other unixlibs in `lib/wine/x86_64-unix/`, which is
  where Wine looks for a builtin DLL's Unix side. If it is missing, `winemetal.dll` fails to load and so do
  `d3d11.dll`/`dxgi.dll`.

Optional environment variables (from DXMT's docs):

| Variable | Effect |
|---|---|
| `DXMT_LOG_LEVEL=none\|error\|warn\|info\|debug` | Log verbosity (stderr) |
| `DXMT_LOG_PATH=/dir` | Also write `<exe>_d3d11.log` etc. there; `none` disables log files |
| `DXMT_SHADER_CACHE=0` | Disable the shader cache |
| `DXMT_SHADER_CACHE_PATH=/abs/darwin/dir` | Shader cache location (default `$(getconf DARWIN_USER_CACHE_DIR)/dxmt/<exe>`) |
| `DXMT_CONFIG_FILE=/path/dxmt.conf` | Per-game options (see the bundled `dxmt.conf`) |
| `MTL_HUD_ENABLED=1` | Apple's Metal performance HUD (works for any Metal app) |

## `dxvk-macos-<version>.tar.xz` (Direct3D 9/10/11 → Vulkan → MoltenVK)

```
dxvk/
  x64/d3d9.dll d3d10core.dll d3d11.dll dxgi.dll     # 64-bit PE
  x32/d3d9.dll d3d10core.dll d3d11.dll dxgi.dll     # 32-bit PE
  LICENSE                                           # zlib
  VERSION                                           # tag and commit
  dxvk.conf                                         # sample config (all options commented out)
```

The 1.10.x macOS fork is used because upstream DXVK 2.x needs Vulkan features MoltenVK
does not provide. These are ordinary native PE DLLs (not Wine builtins) and do not depend on a
particular Wine build, only on Wine's `winevulkan` + MoltenVK (bundled in our Wine tarball).

### Installing DXVK

Into the bottle (prefix), not the Wine tree, so stock Wine stays usable for other bottles:

| File | Goes to |
|---|---|
| `dxvk/x64/*.dll` | `<prefix>/drive_c/windows/system32/` |
| `dxvk/x32/*.dll` | `<prefix>/drive_c/windows/syswow64/` |

Then set the DLL overrides to native-then-builtin, either per process:

```
WINEDLLOVERRIDES="dxgi,d3d9,d3d10core,d3d11=n,b"
```

or persistently in the prefix (`HKCU\Software\Wine\DllOverrides`, values `dxgi`, `d3d9`,
`d3d10core`, `d3d11` = `native,builtin`). Override `dxgi` too: DXVK's `d3d11` needs DXVK's
`dxgi` adapter. To use DXVK for D3D9 only, copy and override only `d3d9`.

To uninstall: remove the overrides and run `wineboot -u` to restore Wine's DLLs.

Do not combine with DXMT in the same Wine tree and prefix: DXMT needs those DLLs as builtin,
DXVK needs them overridden to native.

Optional environment variables:

| Variable | Effect |
|---|---|
| `DXVK_ASYNC=1` | Compile pipelines asynchronously (fork-specific; less stutter, possible brief glitches) |
| `DXVK_HUD=fps,devinfo,...` | On-screen HUD |
| `DXVK_LOG_LEVEL=none\|error\|warn\|info\|debug` | Log verbosity (stderr) |
| `DXVK_LOG_PATH=/dir` | Also write `<exe>_d3d11.log` etc. there |
| `DXVK_CONFIG_FILE=/path/dxvk.conf` | Per-game options |
| `DXVK_STATE_CACHE_PATH=/dir` | Pipeline state cache location |

## Smoke test

`build-graphics.yml`'s `smoke-test` job does both installs exactly as above, then runs
`tests/d3d11-smoke.c` (64- and 32-bit), which loads `d3d11.dll`, checks that the expected
backend was loaded (`winemetal.dll` present for DXMT, the DXVK banner in the log for DXVK),
creates a D3D11 device and clears a render target. Logs are uploaded as `smoke-test-logs`.
A backend whose DLLs do not load fails the job. A device that cannot be created on the CI
VM's virtual GPU only produces a warning (`STRICT_DEVICE=1` makes it fatal).
