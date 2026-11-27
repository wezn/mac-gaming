# Testing mg on a real Mac

This is the plan for the first hands-on session with `mg` (see [launcher/README.md](../launcher/README.md))
on an Apple Silicon Mac with real backends. CI can only prove that Wine starts and that DXMT/DXVK create a
D3D11 device on a virtual GPU. Everything below needs real hardware, and most of it needs a person watching
the screen.

**Short version:**

```sh
gh auth login        # once; artifact downloads need it, even from a public repo
gh repo clone wezn/mac-gaming ~/src/mac-gaming
cd ~/src/mac-gaming && git checkout mg-test-kit    # contains #7 and #8 too; or main, once merged
scripts/mg-test-session.sh
```

The script asks before every long step. Press `q` at any prompt to stop: it still writes the report.
When it finishes, attach `~/mg-test/mg-test-<time>.tar.gz` to a GitHub issue and paste the `results.md`
it prints into the issue text.

## What you need

- An Apple Silicon Mac, macOS 15 or newer (14 works, but Rosetta only translates AVX/AVX2 from 15).
- Rosetta 2: `softwareupdate --install-rosetta --agree-to-license`. The script never runs this, or anything
  else, with sudo; it only tells you.
- The GitHub CLI (`brew install gh`), logged in.
- For D3DMetal: your own copy of Apple's Game Porting Toolkit. Mount the "Evaluation environment for
  Windows games" disk image (or copy its contents somewhere). mg never redistributes D3DMetal.
- Disk: about 2 GB for Wine and bottles, plus ~50 GB for Overwatch 2 and ~35 GB for CS2.
- A Battle.net account. For CS2, a **throwaway** Steam account only (see [CS2](#9-cs2-on-steam-throwaway-account-only)).

## What the script does

`scripts/mg-test-session.sh` (run `--help` for options):

1. Finds the newest successful CI runs that still have artifacts: `mg-macos-arm64` from the Launcher workflow,
   `wine-crossover-*` from Build Wine, `dxmt-*` and `dxvk-macos-*` from Build graphics layers. If there are
   no graphics artifacts yet, it says so and skips the DXMT/DXVK steps. Pin runs with `--mg-run`,
   `--wine-run`, `--graphics-run`, or use your own mg build with `--mg PATH`.
2. Downloads them with `gh run download` into `~/mg-test/downloads/` (once per run ID).
3. Installs them into a throwaway mg root, `~/mg-test/home` (`--mg-home DIR` to use another one; your real
   `~/Library/Application Support/mac-gaming` is untouched unless you pass it, and then it asks first).
4. Runs `mg doctor`, asks for your GPTK path (it suggests a mounted GPTK volume if it sees one) and runs
   `mg config set gptk`.
5. Walks through the checklist below, asking before each step and asking pass/fail/skip plus a note after it.
6. Writes `~/mg-test/mg-test-<time>.tar.gz` containing: `results.md` (your answers), `transcript.log`
   (every command and its output), `host.txt` (`sw_vers`, `sysctl machdep.cpu.brand_string`, model,
   Rosetta, display, the GPTK version and folder layout, `mg runtime/bottle list`, the DXMT and D3DMetal overlays),
   `doctor.txt`/`doctor.json`, and `mg report` (settings, runtime manifests, bottle settings, the D3D DLLs in
   each bottle, the newest 30 run logs). Your home folder becomes `~` and your account name `USER` in every
   file. Skim it anyway before posting.

It deletes nothing. To clean up afterwards: `rm -rf ~/mg-test`. Re-running reuses the downloads and the
installed runtime; `--from N` jumps to checklist step N.

### Gatekeeper and the unsigned `mg` binary

The `mg` in the CI artifact is unsigned (it only has the linker's ad-hoc signature, which Apple Silicon
requires). `gh run download` does not set the quarantine flag, so it runs as is. If you download the
artifact with a browser instead, macOS quarantines it and refuses to open it ("cannot be opened because
the developer cannot be verified"). Clear the flag on that one file:

```sh
tar -xzf mg-macos-arm64.tar.gz
xattr -d com.apple.quarantine mg
./mg --version
```

(or System Settings → Privacy & Security → "Open Anyway" after the first refusal). The same applies to
Wine tarballs downloaded with a browser: `xattr -dr com.apple.quarantine` on the extracted folder, or let
`mg runtime install` read the zip directly.

## The checklist, in order

Each step builds on the previous one. A failure early on (Wine does not start) makes the later ones
pointless, so stop and report.

### 1. wined3d sanity: Notepad

`mg bottle create mgtest`, then `mg run --bottle mgtest --backend wined3d notepad.exe`.

**Success:** a Notepad window within ~30 s of `wineboot` finishing, crisp text, typing works, closing it
returns to the script. **Report:** if nothing appears, the transcript and the notepad log (in the report)
usually show a missing library or a macOS driver error.

### 2. Backend selection dry runs

`mg run --dry-run` on the synthetic executables in `launcher/Tests/MGCoreTests/Fixtures`, auto-detected
(dx8, dx9, dx10, dx11, dx12, ddraw, the engine folder) and with each backend forced on `dx11.exe`.
No side effects. **Success:** dx12 → d3dmetal (or a clear "needs GPTK" error), dx11/dx10 → dxmt,
dx9 → dxvk, ddraw → wined3d, `engine/game.exe` → dxmt via `rendersystemdx11.dll`. Forced `dxmt`/`dxvk`
list DLL copies; forced `d3dmetal` uses `wine-d3dmetal/bin/wine`.

### 3. DXVK DLL deploy

Bottle `mgdxvk`: `mg run --backend dxvk --debug +loaddll rundll32.exe d3d11.dll,mgProbe`. rundll32
loads the DLL, does not find the (deliberately bogus) entry point and exits. If an error dialog appears,
close it. The script then checks that `system32/d3d11.dll`, `system32/dxgi.dll` and `syswow64/d3d11.dll` are
byte-identical to DXVK's.

**Success:** `ok:` for all three, and the log shows `system32\d3d11.dll` and `dxgi.dll` loaded as
**native**, with `winevulkan` and MoltenVK behind it.

### 4. DXMT DLL deploy

Bottle `mgdxmt`, same probe with `--backend dxmt`. mg runs DXMT games from `runtimes/<runtime>/wine-dxmt/`:
a copy of `wine/` with DXMT's `d3d11`/`dxgi`/`d3d10core`/`winemetal` DLLs and `winemetal.so` merged into
`lib/wine` (the recipe in [docs/ARTIFACTS.md on `graphics-builds`](https://github.com/wezn/mac-gaming/blob/graphics-builds/docs/ARTIFACTS.md) that the graphics CI proves). Every D3D DLL stays builtin
(`WINEDLLOVERRIDES=...=b`, no `n,b`), and only `winemetal.dll` is copied into the bottle's
`system32`/`syswow64`. The stock `wine/` tree, which the other backends use, is left alone.

The script checks and prints `ok:` or `PROBLEM:` for each of these:

- `runtimes/*/wine-dxmt/lib/wine/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll`,
  `i386-windows/{d3d11,winemetal}.dll` and `x86_64-unix/winemetal.so` are byte-identical to DXMT's;
- `system32/winemetal.dll` and `syswow64/winemetal.dll` are DXMT's;
- the stock `wine/` tree has no `winemetal.so`;
- the run's `WINEDLLOVERRIDES` has no `n,b`;
- the `+loaddll` log shows `winemetal.dll` loading as **builtin**, and no `wined3d.dll` (Wine's own d3d11).

**Success:** all `ok:`. CI checks the same thing on a virtual GPU, so a `PROBLEM:` here points at
something specific to your Mac or to a stale overlay. `mg doctor` should show `winemetal integrated:
<path>`, and it warns if `dxmt/VERSION` names a different Wine build than the one installed.

### 5. D3DMetal overlay

`mg run --backend d3dmetal --debug +loaddll rundll32.exe d3d12.dll,mgProbe` in `mgtest`. The first
D3DMetal run builds `runtimes/<runtime>/wine-d3dmetal/`: an APFS clone of `wine/` with your GPTK `lib`
folder merged into `lib/`.

**Success:** `runtimes/*/wine-d3dmetal/lib/external/D3DMetal.framework` exists (the script lists it),
`mg doctor` shows "D3DMetal overlay", and the log shows `d3d12.dll` loading from the overlay without
"could not load" errors for `D3DMetal` or `libd3dshared.dylib`.

### 6. Battle.net install

`mg battlenet install --bottle ow --backend d3dmetal`. mg downloads Blizzard's installer and runs it with
wined3d. It is interactive: click through, sign in if asked, quit the client if it starts.

**Success:** `C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe` exists in the bottle (step 7
fails with "not installed" otherwise). **Report:** an installer that hangs on a white or black window
(Chromium under wined3d), or one that installs somewhere else.

### 7. Overwatch 2 on D3DMetal

The script sets the bottle to `d3dmetal` with the Metal HUD on and runs `mg battlenet run --bottle ow`.
Install Overwatch 2 from the client the first time (~50 GB). Games started from Battle.net inherit the
client's environment, so the **bottle's** backend is what the game gets.

**Success:** the client renders and logs in, the game reaches the main menu, the Practice Range runs
with sensible input. **Report:** fps from the Metal HUD (top right) at your resolution and settings,
stutter, crashes (the newest `Overwatch`/`Battle.net` logs are in the report).

### 8. Overwatch 2 on DXMT

Same bottle, `mg bottle set ow --backend dxmt`. Note that the Battle.net client's own Chromium UI now
also runs on DXMT; if the client is blank, that alone is worth reporting.

**Success / report:** as step 7. The interesting result is the comparison: fps, stutter while shaders
compile, visual glitches.

### 9. Retina and HUD toggles, msync on/off

- **Retina** (`mg bottle set ow --retina`): renders at full Retina resolution. Expect a sharper picture
  and lower fps. mg writes `HKCU\Software\Wine\Mac Driver\RetinaMode` only when the setting changes, so
  check the change actually took effect (a sharper client UI is the easiest tell). The script turns it
  back off afterwards.
- **HUD** (`--hud` / `--no-hud`): Apple's Metal performance HUD (`MTL_HUD_ENABLED=1`). Should appear on
  both D3DMetal and DXMT, since both are Metal.
- **msync off** (`mg bottle set ow --no-msync`): falls back to Wine's server-side sync. Expect higher CPU
  use and maybe lower fps. If the game is *more* stable without msync, that matters.

### 10. Steam install

`mg steam install --bottle cs2 --backend dxmt` (d3dmetal without DXMT). Runs `SteamSetup.exe /S`.

**Success:** no window, the command finishes, and `C:\Program Files (x86)\Steam\steam.exe` exists.

### 11. CS2 on Steam (throwaway account only)

**VAC risk:** whether Valve's anti-cheat bans accounts playing under Wine/D3DMetal/DXMT is unknown
([docs/PLAN.md](PLAN.md)). Use a throwaway account, and play offline against bots, never matchmaking.
The script asks you to type `throwaway` before it starts Steam.

`mg steam run --bottle cs2` starts Steam with `-cef-disable-gpu-compositing -cef-in-process-gpu`.
**Success:** the Steam window renders (store and library visible), it updates itself, CS2 installs and
reaches the menu, an offline bot match runs. Also worth one try each: CS2's `-vulkan` launch option
(Vulkan through MoltenVK instead of D3D11), and the bottle on `d3dmetal` instead of `dxmt`.

## Guesses that most need checking

These are in mg's code but have never been tried on a Mac. Each step above that touches them asks you
to look, and the report collects what is needed to fix them.

| Guess | Where | How the session checks it |
|---|---|---|
| The GPTK lib folder looks like `redist/lib/{external/D3DMetal.framework, external/libd3dshared.dylib, wine/x86_64-windows/*.dll, wine/x86_64-unix/*.so}`. mg also accepts the volume root, `redist`, `lib`, an app bundle's `Contents/Resources/wine/lib` and `wine/lib` | `GPTKInstall.resolve` in `launcher/Sources/MGCore/BackendFiles.swift` | `mg config set gptk` accepts or rejects your folder; the report has the folder listing (4 levels deep) and the D3DMetal.framework version from its `Info.plist`, so a different layout (GPTK 3.x?) can be added |
| DXMT, merged into `wine-dxmt/` and loaded as builtin, renders real games (CI only creates a device on a virtual GPU) | `BackendFiles.ensureDXMTOverlay` | Steps 4 and 8 |
| D3DMetal works when the GPTK `lib` folder is merged over Wine's `lib/` (`wine-d3dmetal/`) and `lib/external` is on `DYLD_FALLBACK_LIBRARY_PATH` | `ensureD3DMetalOverlay` | Steps 5 and 7 |
| Steam's installer is silent with `/S`, and the client needs `-cef-disable-gpu-compositing -cef-in-process-gpu` | `Store.steam` in `launcher/Sources/MGCore/Installers.swift` | Steps 10 and 11. The URL itself is fine: `https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe` returned a 2.3 MB PE on 2026-11-27 |
| Battle.net's installer URL and the client path `C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe` | `Store.battlenet` | Step 6. The URL (`https://www.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live`) returned a 4.7 MB PE on 2026-11-27; the install path is unverified |

## What to send back

1. The tarball the script prints (`~/mg-test/mg-test-<time>.tar.gz`), attached to a new issue.
2. `results.md` pasted into the issue text, so it is readable without downloading anything.
3. For anything that crashed or rendered wrong: what you saw (a screenshot helps), and if you can, the same
   run again with more logging, then `mg report`:

   ```sh
   export MG_HOME=~/mg-test/home
   ~/mg-test/bin/mg run --bottle ow --debug +loaddll,+seh,+err -v "C:\\path\\to\\Game.exe"   # or battlenet run -v
   ~/mg-test/bin/mg report            # writes ./mg-report-<time>.tar.gz
   ```

`mg report` is useful on its own too: it bundles `mg doctor` (text and JSON), settings, runtime manifests,
the DXMT and D3DMetal overlay state (including which `wine-dxmt` DLLs are DXMT's), bottle settings and the newest run logs (`--logs N`, each cut to its last
`--log-kib` KiB), with home paths redacted. `mg doctor --json` prints the checks as JSON.

If the script itself fails (a download, an unexpected prompt), `~/mg-test/sessions/<time>/transcript.log`
has everything it ran, and `scripts/mg-test-session.sh --package-only --mg ~/mg-test/bin/mg --mg-home ~/mg-test/home`
packages a report without running anything.
