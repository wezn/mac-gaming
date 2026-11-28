# mgx: the mac-gaming launcher

`mgx` runs Windows games on Apple Silicon Macs with the Wine build from this repo and a graphics
backend picked per game. (It was called `mg`, but macOS already ships `/usr/bin/mg`, a small Emacs-like
editor, so typing `mg` could open that instead. The data folder, `MG_HOME` and the `.mg-*.json`
state files keep their old names, so existing setups keep working.) It is a Swift package with three targets:

- **MGCore**: all the logic (runtimes, bottles, backend selection, PE import scanning, environment
  construction, process launch, doctor). It depends only on Foundation.
- **mgx**: a thin command-line front end built on swift-argument-parser.
- **MacGamingApp**: a SwiftUI app on top of MGCore (macOS only; see [App](#app)).

## Build

```sh
cd launcher
swift build -c release
cp .build/release/mgx /usr/local/bin/   # optional
swift test
```

macOS 13+ is required at run time. macOS 15+ is recommended: Rosetta 2 translates AVX/AVX2 only from macOS 15.

**Prebuilt:** every Launcher workflow run uploads an arm64 release build as the `mgx-macos-arm64` artifact
(`mgx-macos-arm64.tar.gz` plus its SHA-256). It is unsigned: `gh run download` leaves it runnable, but a copy
downloaded with a browser is quarantined and needs `xattr -d com.apple.quarantine mgx` first.

**Testing on a Mac:** `scripts/mgx-test-session.sh` downloads the newest mgx, Wine and DXMT/DXVK builds, installs
them into a throwaway root and walks through a checklist. See [docs/TESTING.md](../docs/TESTING.md).

## App

`MacGaming.app` is a native front end for the same bottles and runtimes: the app and `mgx` share the
data folder, so either can be used at any time.

```sh
cd launcher
Scripts/make_app.sh            # swift build + bundle → build/MacGaming.app (ad-hoc signed)
open build/MacGaming.app
```

Or download the `MacGaming-app` artifact from the latest [Launcher workflow](../.github/workflows/launcher.yml)
run, unzip it, and clear the quarantine flag (the app is not notarized yet):
`xattr -dr com.apple.quarantine MacGaming.app`.

What it does (v1):

- **Bottles** (sidebar): create (runs wineboot in the background), delete, and edit the runtime,
  backend, msync, Retina, Metal HUD and environment variables. Edits are saved with Save (⌘S).
- **Run…** (⌘R): pick an `.exe`/`.msi`/`.bat`, review the launch plan (detected DirectX level and
  evidence, the chosen backend and why, warnings, DLL copies, the command, and every environment
  variable that differs from the app's environment), change the bottle, backend or arguments
  (re-planned as you edit), then Launch.
- **Steam / Battle.net**: Install and Open buttons per bottle (same flow as `mgx steam|battlenet install|run`).
- **Wine Tools**: winecfg, regedit, explorer, taskmgr, notepad. **Stop All** runs `wineserver -k`.
- **Runtimes**: install from a file picker or by dropping archives, zipped CI artifacts or folders;
  make default; remove. Each runtime shows whether its `wine-dxmt/` overlay is current and warns
  when DXMT was built against a different Wine; the run plan names the Wine tree it will use.
- **Doctor**: the `mgx doctor` checks. **Copy Diagnostics** puts a redacted `mgx report` (without
  logs) on the clipboard; **Save Report…** writes the full `.tar.gz`. **Logs**: every run log, with a live tail.
- **Activity**: each background job (wineboot, an install, a running program) with mgx's progress
  lines and its Wine log, tailing live. Settings (⌘,): GPTK path, default runtime and bottle.

Long-running work never blocks the main thread: views call view models in the app target, which run
MGCore's synchronous APIs through `Blocking.run` (MGCore/Async.swift: one thread per call, so waiting
on Wine for hours does not tie up Swift's cooperative pool). `Subprocess.run(...) async` is also
available and terminates the child when its task is cancelled. Logic the app needs beyond views
(bottle/settings/store actions, `LaunchPlan.environmentChanges`, `LogTail`, `ArgumentSplitter`) lives
in MGCore with unit tests, and the CLI uses the same code.

The app target is only declared on macOS (`#if os(macOS)` in Package.swift), so `swift build` and
`swift test` still work on Linux. CI builds the bundle on `macos-15`, launches it headlessly against a
demo data folder (it must stay up for 8 seconds per screen), and uploads the app and screenshots.
`-MGInitialSection runtimes|doctor|logs|bottle:<name>` and `-MGPreviewRun <exe>` choose the first
screen (used for the screenshots).

**Not done yet:** signing with a Developer ID, the hardened runtime and notarization need the owner's
certificate and Apple ID (see the TODO in `Scripts/make_app.sh`). Quitting the app does not stop
running games (use Stop All first).

## Quick start

```sh
# 1. Install the Wine build (and optionally graphics backends). Pass files, zipped CI
#    artifacts, or a directory containing them.
mgx runtime install ~/Downloads/wine-crossover-26.3.0-wow64.tar.xz \
                   ~/Downloads/dxmt-0.80.tar.xz ~/Downloads/dxvk-macos-1.10.3-20230507-repack.tar.xz

# 2. Optional: point mgx at your own Game Porting Toolkit for D3DMetal (needed for DX12).
mgx config set gptk "/Volumes/Evaluation environment for Windows games 2.1"

# 3. Check the setup.
mgx doctor

# 4. Run something.
mgx run ~/Games/SomeGame/Game.exe -windowed
```

## Commands

| Command | What it does |
|---|---|
| `mgx runtime install <path>...` | Install `wine-crossover-*.tar.xz`, `dxmt-*.tar.xz`, `dxvk-macos-*.tar.xz` (or zips / directories containing them). `--name`, `--set-default` |
| `mgx runtime list` / `remove <name>` | List or remove runtimes |
| `mgx bottle create <name>` | Create a bottle and run `wineboot --init`. `--runtime`, `--backend`, `--no-msync`, `--retina`, `--hud`, `--env K=V`, `--no-init`, `--set-default` |
| `mgx bottle list` / `show <name>` | List bottles, or print a bottle's path and config |
| `mgx bottle set <name>` | Change settings: `--backend`, `--runtime`, `--[no-]msync`, `--[no-]retina`, `--[no-]hud`, `--env K=V`, `--unset-env K` |
| `mgx bottle stop <name>` | Kill every Wine process in the bottle (`wineserver -k`) |
| `mgx bottle delete <name> [-y]` | Delete the bottle and everything installed in it |
| `mgx run [options] <program> [args...]` | Run a program. See below |
| `mgx detect <exe>` | Show an executable's imports and detected DirectX version |
| `mgx steam install --bottle B` / `mgx steam run --bottle B` | Download the official Steam installer, install silently, start the client |
| `mgx battlenet install --bottle B` / `mgx battlenet run --bottle B` | Same for Battle.net (its installer is interactive) |
| `mgx config [show]` / `set <key> <value>` / `unset <key>` | Keys: `gptk`, `default-runtime`, `default-bottle` |
| `mgx doctor` | Check macOS version, Apple Silicon, Rosetta, runtimes, MoltenVK, DXMT, DXVK, the GPTK path (and its version), the D3DMetal overlay and bottles. Exits 1 on errors. `--json` for machine-readable output |
| `mgx report` | Bundle host facts, doctor (text and JSON), settings, runtime manifests, the DXMT and D3DMetal overlay state, bottle settings and the newest logs into `mgx-report-<time>.tar.gz` for a bug report. `$HOME` becomes `~`, your account name `USER`. `-o PATH` (a directory unless it ends in `.tar.gz`), `--logs N`, `--log-kib N` |
| `mgx logs` | List per-run logs. `--last` prints the newest, `--path` prints paths only, `--bottle B`, `-n N` |

### `mgx run`

```
mgx run [--bottle B] [--backend auto|d3dmetal|dxmt|dxvk|wined3d] [--env K=V]...
       [--[no-]hud] [--[no-]msync] [--[no-]retina] [--debug CHANNELS] [-v] [--dry-run]
       <program> [args...]
```

- `<program>` is a path on disk (scanned for DirectX imports and run from its own folder), a
  `C:\` path inside the bottle, or a program Wine provides (`notepad.exe`, `winecfg`, `regedit`).
  `.msi` files go through `msiexec /i` and `.bat`/`.cmd` files through `cmd /c`.
- Everything after `<program>` goes to the program unchanged, including things that look like flags.
- Without `--bottle`, mgx uses the default bottle (`mgx config set default-bottle`), else a bottle
  named `default`, which is created on first use.
- Wine's output goes to the run's log file. `-v` also prints it to the terminal.
- `--dry-run` prints the detected DirectX version, the chosen backend and why, the DLLs that would be
  copied, the command, and every environment variable that differs from your shell, then exits.
- `mgx` waits for the program and exits with its exit code.

What a run sets up:

| | |
|---|---|
| `WINEPREFIX` | the bottle directory |
| `WINEMSYNC=1` | on by default (`--no-msync` or `mgx bottle set B --no-msync`) |
| `WINEDLLOVERRIDES` | every D3D/DXGI DLL pinned to builtin, then the backend's DLLs set to `n,b`. Merged with any `WINEDLLOVERRIDES` from your shell, the bottle, the game override or `--env` (those win) |
| `DYLD_FALLBACK_LIBRARY_PATH` | the runtime's `wine/lib` (bundled MoltenVK and freetype), plus D3DMetal's `external/` when used |
| `WINEDEBUG=-all` | unless you set it (`--debug +loaddll`) |
| `MTL_HUD_ENABLED=1` | with `--hud` or a bottle with the HUD on |
| Retina | written to `HKCU\Software\Wine\Mac Driver\RetinaMode` only when the setting changes, together with `HKCU\Control Panel\Desktop\LogPixels` = 192 (on) or 96 (off): Retina mode works in device pixels, so without 200% DPI apps are drawn at half size |

Stray `WINELOADER`, `WINESERVER`, `WINEDLLPATH` and `WINEARCH` from your shell are dropped.

### Backend selection

Precedence: `--backend` > per-game override > the bottle's `backend` > auto-detection.

Auto-detection reads the PE import and delay-import tables of the executable. If the executable
imports no Direct3D DLL, mgx checks the DLLs next to it (engines such as Source 2 load their renderer at
run time).

| Detected | Backend |
|---|---|
| DirectX 12 (`d3d12.dll`) | D3DMetal; error if GPTK is not configured |
| DirectX 11 / 10 (`d3d11`, `dxgi`, `d3d10*`) | DXMT, then D3DMetal, then DXVK, then wined3d |
| DirectX 9 | DXVK, then wined3d |
| DirectX 8 | DXVK if it ships `d3d8.dll`, else wined3d |
| DirectDraw / nothing found | wined3d |

How each backend is wired:

- **dxmt**: DXMT's DLLs are Wine *builtins* linked against one Wine build (`dxmt/VERSION` says which;
  `mgx doctor` warns on a mismatch). Wine loads builtins from its own `lib/wine` even when a copy sits
  in `system32`, so mgx runs DXMT from `runtimes/<r>/wine-dxmt/`: an APFS clone of `wine/` with DXMT's
  `x86_64-windows/*.dll`, `i386-windows/*.dll` and `x86_64-unix/winemetal.so` merged into `lib/wine`.
  It is built by `mgx runtime install` and rebuilt when Wine or DXMT changes. Every D3D DLL stays
  builtin (no `n,b`). `winemetal.dll` is copied into the bottle's `system32`/`syswow64`, because
  `wineboot` does not put it there. `wine/` stays stock for wined3d and DXVK bottles.
- **dxvk**: `x64/*.dll` → `system32`, `x32/*.dll` → `syswow64`, all `n,b`.
- **d3dmetal**: D3DMetal replaces Wine builtins, so mgx runs it from `runtimes/<r>/wine-d3dmetal/`, an
  APFS clone of `wine/` with your GPTK `lib/` folder merged in (the layout of Apple's evaluation
  environment). It is built on first use and rebuilt when Wine or the GPTK changes. mgx never
  redistributes D3DMetal.
- **wined3d**: no copies; all D3D DLLs builtin.

DLLs are real copies (APFS clones, so they use no extra space), not symlinks: wineboot rewrites
`system32` on prefix updates and would write through a symlink into the runtime. A copy happens only
when size or modification time differ, so repeat launches do no I/O.

**Launchers:** games started from Steam or Battle.net inherit the client's environment, so
auto-detection on `steam.exe` cannot help. Give launcher bottles a backend:

```sh
mgx battlenet install --bottle ow --backend d3dmetal
mgx battlenet run --bottle ow
```

`mgx battlenet install` / `run` also save `WINE_SIMULATE_WRITECOPY=1` in the bottle (unless you set it
yourself): without it Battle.net's built-in browser crashes (`int3` in `libcef`) and the client closes
with "encountered a serious problem". `mgx battlenet run` starts the client with
`--in-process-gpu --disable-gpu-compositing`: without them the window freezes or stays black (DXMT
cannot present from Chromium's separate GPU process). The Battle.net probe workflow
(`.github/workflows/battlenet.yml`) checks both on a CI Mac. The installer starts the client once
without these switches; if that window freezes, quit it and use `mgx battlenet run`.

### Per-game overrides

`overrides.json` in the mgx root, merged over the built-in table and keyed by executable name
(case-insensitive):

```json
{
  "games": {
    "Overwatch.exe": { "backend": "d3dmetal" },
    "cs2.exe":       { "dx": 11 },
    "OldGame.exe":   { "backend": "dxvk", "env": { "DXVK_HUD": "fps" }, "retina": true, "msync": false }
  }
}
```

Fields: `backend`, `dx` (the DirectX level auto-selection should assume: `7`–`12`, or `"dx11"`),
`env`, `retina`, `msync`, `note`. Built in: `Overwatch.exe` → D3DMetal and `cs2.exe` → DX11 (so DXMT).

## Files

Everything lives under `~/Library/Application Support/mac-gaming` (set `MG_HOME` to move it):

```
config.json                 default runtime / bottle, GPTK path
overrides.json              your per-game overrides
runtimes/<name>/            wine/, dxmt/, dxvk/, wine-dxmt/ and wine-d3dmetal/ (generated), runtime.json
bottles/<name>/             the Wine prefix (drive_c, *.reg) plus bottle.json
logs/<bottle>/<time>-<exe>.log   one per run, newest 50 kept per bottle
cache/installers/           SteamSetup.exe, Battle.net-Setup.exe
```

`bottle.json`:

```json
{
  "backend" : "auto",
  "created" : "2026-11-27T06:00:00Z",
  "env" : { },
  "metalHUD" : false,
  "msync" : true,
  "name" : "test",
  "retina" : false
}
```

`runtime` is omitted when the bottle follows the default runtime. `MG_GPTK` overrides the
configured GPTK path for one command.

## Design notes

- **No shell in the launch path.** Wine and helper tools are started with `posix_spawn` and an
  explicit environment. Downloads use `/usr/bin/curl` (HTTPS only), archives use `/usr/bin/tar` and `ditto`.
- **Planning has no side effects.** `Launcher.plan` resolves everything (bottle, runtime, detection,
  backend, environment) without touching disk, `prepare` makes the bottle match (each step skipped
  when already done), and `execute` starts Wine. `--dry-run` stops after the plan, and a GUI can show it.
- **PE scanning is cheap.** The executable is memory-mapped and only the headers, section table and
  import descriptors are read, so a multi-gigabyte game binary costs a few page faults.
- `wineboot --init` runs with `mscoree` and `mshtml` disabled, so a fresh bottle never blocks on the
  wine-mono/wine-gecko download prompt. Install wine-mono yourself if a program needs .NET.

## Tests

`swift test` runs on macOS and Linux. The PE fixtures in `Tests/MGCoreTests/Fixtures` are tiny
synthetic images made by `Scripts/make_fixtures.py` (cross-checked with the `pefile` Python module).
Launch tests use a fake `wine` script, so they need no Wine install. CI (`.github/workflows/launcher.yml`)
also runs a smoke test on `macos-15` against the real Wine artifact from the latest successful
`Build Wine` run: create a bottle, run `cmd.exe /c echo`, and keep `notepad.exe` up for 30 seconds
with wined3d. It then installs the DXMT and DXVK-macOS artifacts from the latest successful
`Build graphics layers` run, checks `mgx doctor`, `mgx runtime list` and the `--dry-run` plans for the
DX11/DX9 fixtures, runs `cmd.exe /c echo` with `--backend dxmt` and `--backend dxvk` (checking the
DLLs that land in `system32`/`syswow64`), and loads each backend's `d3d11.dll` with `rundll32` under
`+loaddll` to see which DLLs Wine picks. Nothing is rendered. Steps that need an artifact are skipped
with a warning when no successful run exists yet. The logs and an `mgx report` are uploaded as `smoke-logs`.
