# Installing MacGaming

MacGaming runs Windows games on Apple Silicon Macs. You need:

- a Mac with Apple Silicon (M1 or later);
- macOS 13 or later; macOS 15 or later is recommended (Rosetta 2 translates AVX/AVX2 only from macOS 15);
- Rosetta 2. macOS offers to install it the first time it is needed, or run
  `softwareupdate --install-rosetta --agree-to-license` in Terminal.

Everything is on the [Releases page](https://github.com/wezn/mac-gaming/releases/latest):

| File | What it is |
|---|---|
| `MacGaming-<version>.zip` | The app |
| `wine-crossover-<cx>-wow64.tar.xz` | The Windows compatibility runtime (required) |
| `dxmt-<version>.tar.xz`, `dxvk-macos-<version>.tar.xz` | Graphics backends for DirectX 9/10/11 games (recommended) |
| `mgx-<version>-macos-arm64.tar.gz` | The `mgx` command-line tool (optional; same bottles and runtimes as the app) |
| `SHA256SUMS` | Checksums of every file |
| `crossover-sources-*.tar.gz`, `nettle-*.tar.gz` | Source code of the open-source runtime parts (you do not need these) |

## 1. Install the app

1. Download `MacGaming-<version>.zip`. Safari usually unzips it for you; otherwise double-click it in
   Downloads.
2. Drag **MacGaming** into your **Applications** folder.

## 2. Open it the first time ("Open Anyway")

MacGaming is not notarized by Apple yet, so the first time you open it macOS blocks it. You approve it
once in System Settings; after that it opens normally.

> **macOS 15 Sequoia and macOS 26 Tahoe:** Control-clicking (right-clicking) the app and choosing
> **Open** no longer gets you past this. Use **Open Anyway** in System Settings as described below.

1. Double-click **MacGaming** in Applications. macOS says the app was **Not Opened** because "Apple
   could not verify it is free of malware". Click **Done**. (Do not click **Move to Trash**.)
2. Open **System Settings** (Apple menu → System Settings…) and click **Privacy & Security** in the
   sidebar.
3. Scroll down to the **Security** section. It says the app **was blocked to protect your Mac**.
   Click **Open Anyway**. (The button is shown for about an hour after you tried to open the app. If it
   is not there, do step 1 again.)
4. Enter your password or use Touch ID when asked.
5. macOS asks once more whether to open MacGaming. Click **Open Anyway**.

From now on MacGaming opens like any other app. After an update you may have to approve the new
version the same way.

If you are comfortable with Terminal, this does the same as steps 1–5:

```sh
xattr -dr com.apple.quarantine /Applications/MacGaming.app
```

## 3. Install the runtimes

The app does not include the Windows runtime; you download it once from the same release.

1. Download `wine-crossover-<cx>-wow64.tar.xz`, `dxmt-<version>.tar.xz` and
   `dxvk-macos-<version>.tar.xz`.
2. Files downloaded with a browser carry macOS's quarantine flag, and so would every Wine program
   unpacked from them. Clear the flag on the downloads first (Terminal):

   ```sh
   cd ~/Downloads
   xattr -d com.apple.quarantine wine-crossover-*-wow64.tar.xz dxmt-*.tar.xz dxvk-macos-*.tar.xz
   ```

3. In MacGaming, open **Runtimes** in the sidebar and install the three files (choose them, or drop them
   onto the window). Or, with `mgx`: `mgx runtime install ~/Downloads/wine-crossover-*-wow64.tar.xz
   ~/Downloads/dxmt-*.tar.xz ~/Downloads/dxvk-macos-*.tar.xz`.
4. Open **Doctor** in the sidebar (or run `mgx doctor`) to check the setup.

DirectX 12 games need Apple's D3DMetal, which MacGaming is not allowed to include: install Apple's Game
Porting Toolkit yourself and choose it in MacGaming's Settings (`mgx config set gptk <path>`).

## Optional: the `mgx` command-line tool

```sh
cd ~/Downloads
tar -xzf mgx-<version>-macos-arm64.tar.gz     # gives mgx and THIRD_PARTY_NOTICES.md
xattr -d com.apple.quarantine mgx             # only if you downloaded it with a browser
./mgx --version
```

Keep `THIRD_PARTY_NOTICES.md` next to `mgx` (`mgx licenses` prints it). To run `mgx` from anywhere, put
both files in a folder of your own and link to it, e.g. `ln -s ~/mgx/mgx /usr/local/bin/mgx`. If you skip
the `xattr` step, macOS blocks `mgx` the first time: approve it with **Open Anyway** as in step 2.

## Checking your downloads

Each release has a `SHA256SUMS` file. To check one download:

```sh
cd ~/Downloads
grep ' MacGaming-<version>.zip$' SHA256SUMS | shasum -a 256 -c
```

## Licenses

MacGaming includes open-source software (Wine, DXMT, DXVK-macOS, MoltenVK and others). Their licenses
are in **Mac Gaming → Acknowledgements…** (the app menu), in `mgx licenses`, and in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
