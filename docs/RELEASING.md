# Releasing

A release is a GitHub Release `v<version>` made by [`.github/workflows/release.yml`](../.github/workflows/release.yml).
It builds `MacGaming.app` and `mgx` from the tagged commit, takes the runtimes from the newest
successful **Build Wine** and **Build graphics layers** runs (they are not rebuilt: Wine takes hours),
and publishes everything with checksums and a manifest. Users install it as described in
[INSTALL.md](INSTALL.md).

The app is **ad-hoc signed and not notarized** (no Apple Developer ID yet): users approve it once with
**Open Anyway**. The workflow checks that the signature is ad hoc and valid (`codesign --verify --strict`).

## Assets (a contract)

The in-app updater reads `https://github.com/wezn/mac-gaming/releases/latest/download/manifest.json`, so
these names must not change:

| Asset | Contents |
|---|---|
| `MacGaming-<version>.zip` | `MacGaming.app` (`ditto -c -k --keepParent`), with `Contents/Resources/THIRD_PARTY_NOTICES.md` |
| `mgx-<version>-macos-arm64.tar.gz` | `mgx` and `THIRD_PARTY_NOTICES.md` at the top level |
| `wine-crossover-<cx>-wow64.tar.xz` | the Wine runtime, as built by `build-wine.yml` |
| `dxmt-<v>.tar.xz`, `dxvk-macos-<v>.tar.xz` | the graphics layers, as built by `build-graphics.yml` |
| `SHA256SUMS` | `<sha256>  <file>` for every other asset (`shasum -a 256 -c SHA256SUMS`) |
| `manifest.json` | see below |
| `crossover-sources-<cx>.tar.gz`, `nettle-<v>.tar.gz` | corresponding source of the LGPL parts of the Wine runtime |

`manifest.json` (written by [`scripts/release-manifest.py`](../scripts/release-manifest.py)):

```json
{
  "version": "0.1.0",
  "published": "2026-11-28T12:00:00Z",
  "app": { "file": "MacGaming-0.1.0.zip", "sha256": "…" },
  "mgx": { "file": "mgx-0.1.0-macos-arm64.tar.gz", "sha256": "…" },
  "runtime": [
    { "kind": "wine", "file": "wine-crossover-26.3.0-wow64.tar.xz", "version": "26.3.0", "sha256": "…" },
    { "kind": "dxmt", "file": "dxmt-0.80.tar.xz", "version": "0.80", "sha256": "…" },
    { "kind": "dxvk", "file": "dxvk-macos-1.10.3-20230507-repack.tar.xz", "version": "1.10.3-20230507-repack", "sha256": "…" }
  ]
}
```

`releases/latest` skips drafts and prereleases, so it always describes the newest published release.

## Before a release

1. **Runtime builds exist.** The workflow takes the newest successful run of each workflow whose
   artifacts have not expired (GitHub keeps them for 90 days). Rebuild them first if they are too old
   or if a build script changed: Actions → *Build Wine* / *Build graphics layers* → Run workflow. DXMT
   must be built against the same CrossOver version as the Wine artifact (the workflow checks
   `dxmt/VERSION`). To use particular runs, pass `wine_run_id` / `graphics_run_id` to a manual run.
2. **Third-party notices are current.** [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) names the
   exact versions it covers. When any of these changes, update the file (versions, copyright lines and,
   if the upstream license file changed, its text):
   - `CX_VERSION` (`crossover_version` input; also the SHA-256 of `crossover-sources-<cx>.tar.gz`, which
     the workflow verifies the download against), `MVK_VERSION`, `NETTLE_VERSION`/`NETTLE_SHA256` in
     `scripts/build-wine.sh`, and the libraries CrossOver bundles (`sources/wine/libs/*`,
     `sources/freetype`, `sources/gnutls`);
   - `DXMT_TAG` in `scripts/build-dxmt.sh`, `LLVM_VERSION` in `scripts/build-llvm.sh`,
     `LLVM_MINGW_VERSION` in `scripts/build-dxmt.sh`;
   - `DXVK_TAG` in `scripts/build-dxvk.sh` and `patches/dxvk-macos/`;
   - the Homebrew mingw-w64 / GCC version (not pinned: check `strings -a dxvk/x64/d3d11.dll | grep 'GCC: ('`);
   - swift-argument-parser in `launcher/Package.resolved`.

   The workflow fails if the notices do not mention the CrossOver, DXMT, DXVK-macOS, MoltenVK and Nettle
   versions of the artifacts it is about to publish. License texts must come from the actual sources
   (the CrossOver source tarball, the pinned upstream tags), never from memory.
3. **D3DMetal is never shipped.** Apple's license allows only non-commercial redistribution. The
   workflow fails if any asset contains D3DMetal or GPTK files.

## Cutting a release

1. Bump `MGVersion.string` in [`launcher/Sources/MGCore/Paths.swift`](../launcher/Sources/MGCore/Paths.swift)
   (it is `mgx --version` and the app's `CFBundleShortVersionString`) in a pull request, and merge it.
   The tag must equal it: the workflow fails on a mismatch.
2. Optional but recommended, a dry run: Actions → *Release* → Run workflow on `main` with the version.
   This creates a **draft** release `v<version>` (no tag yet, invisible to users). Check its assets, then
   delete it, otherwise the real run fails because the release exists:

   ```sh
   gh release view v0.1.0 --json assets --jq '.assets[].name'
   gh release download v0.1.0 --pattern manifest.json --dir /tmp/check && cat /tmp/check/manifest.json
   gh release delete v0.1.0 --yes --cleanup-tag
   ```

3. Tag the merged commit on `main` and push the tag:

   ```sh
   git fetch origin
   git tag -a v0.1.0 -m "MacGaming 0.1.0" origin/main
   git push origin v0.1.0
   ```

   The workflow refuses a tag that is not on `main`. It publishes the release with the notes GitHub
   generates from the merged pull requests, preceded by install instructions and the runtime runs used.
4. Check `https://github.com/wezn/mac-gaming/releases/latest/download/manifest.json` shows the new version.

A version with a pre-release part (`0.2.0-beta.1`) is published as a prerelease: testers can download it,
but `releases/latest` (and so the updater) keeps pointing at the previous release.

## If something goes wrong

- The workflow fails before *Publish the release*: nothing was published. Fix it and re-run (for a
  tag: delete and re-push the tag, or re-run the failed jobs).
- `gh release create` uploads the assets to a draft and publishes it only when all are uploaded. If it
  fails halfway, a draft is left behind: delete it (`gh release delete v<version> --yes`) and re-run.
- A published release is wrong: do not replace assets in place (the updater may have cached its
  checksums). Publish a new patch version instead.

## Later: Developer ID and notarization

When there is an Apple Developer ID, sign with the hardened runtime and notarize in this workflow (see the
TODO in `launcher/Scripts/make_app.sh`). That needs the certificate and an App Store Connect key as
secrets of a protected `release` environment, never available to pull requests. Then INSTALL.md's
Open Anyway section can go.
