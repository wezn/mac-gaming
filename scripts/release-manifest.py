#!/usr/bin/env python3
"""Write SHA256SUMS and manifest.json for a release directory.

Usage: scripts/release-manifest.py <version> <dir> [--published ISO8601]

<dir> must contain exactly these release files (names are a contract: the in-app updater reads
https://github.com/wezn/mac-gaming/releases/latest/download/manifest.json):

  MacGaming-<version>.zip
  mgx-<version>-macos-arm64.tar.gz
  wine-crossover-<cx>-wow64.tar.xz
  dxmt-<v>.tar.xz
  dxvk-macos-<v>.tar.xz

plus the corresponding source tarballs (crossover-sources-<cx>.tar.gz, nettle-<v>.tar.gz), which are
listed in SHA256SUMS only. Any other file is an error.

manifest.json:
  {"version": "<version>", "published": "<ISO8601>",
   "app": {"file": ..., "sha256": ...}, "mgx": {"file": ..., "sha256": ...},
   "runtime": [{"kind": "wine"|"dxmt"|"dxvk", "file": ..., "version": ..., "sha256": ...}, ...]}
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys

OUTPUTS = {"SHA256SUMS", "manifest.json"}
# (kind, file-name pattern); the group is the component's version, spelled exactly as mgx records it on
# install (RuntimeComponent.version(fromArchive:) in launcher/Sources/MGCore/Runtime.swift), so an updater
# can compare the two: wine-crossover-26.3.0-wow64.tar.xz -> crossover-26.3.0-wow64.
RUNTIME = [
    ("wine", re.compile(r"^wine-(crossover-\d[0-9A-Za-z.]*-wow64)\.tar\.xz$")),
    ("dxmt", re.compile(r"^dxmt-(\d[0-9A-Za-z.+-]*)\.tar\.xz$")),
    ("dxvk", re.compile(r"^dxvk-macos-(\d[0-9A-Za-z.+-]*)\.tar\.xz$")),
]
SOURCES = re.compile(r"^(crossover-sources|nettle)-\d[0-9A-Za-z.]*\.tar\.gz$")
VERSION = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(msg):
    print(f"release-manifest: {msg}", file=sys.stderr)
    sys.exit(1)


def build(version, directory, published):
    if not VERSION.match(version):
        fail(f"bad version {version!r}")
    files = sorted(p.name for p in directory.iterdir() if p.is_file() and p.name not in OUTPUTS)
    if any(p.is_dir() for p in directory.iterdir()):
        fail(f"{directory} must contain only files")
    sums = {name: sha256(directory / name) for name in files}

    def entry(name):
        if name not in sums:
            fail(f"missing {name} in {directory}")
        return {"file": name, "sha256": sums[name]}

    known = {f"MacGaming-{version}.zip", f"mgx-{version}-macos-arm64.tar.gz"}
    unknown = [n for n in files if n not in known and not SOURCES.match(n)
               and not any(p.match(n) for _, p in RUNTIME)]
    if unknown:
        fail(f"unexpected files in {directory}: {unknown}")

    runtime = []
    for kind, pattern in RUNTIME:
        found = [(n, m.group(1)) for n in files for m in [pattern.match(n)] if m]
        if len(found) != 1:
            fail(f"expected exactly one {kind} runtime tarball, found {[n for n, _ in found]}")
        name, v = found[0]
        runtime.append({"kind": kind, "file": name, "version": v, "sha256": sums[name]})

    manifest = {
        "version": version,
        "published": published,
        "app": entry(f"MacGaming-{version}.zip"),
        "mgx": entry(f"mgx-{version}-macos-arm64.tar.gz"),
        "runtime": runtime,
    }
    (directory / "SHA256SUMS").write_text("".join(f"{sums[n]}  {n}\n" for n in files))
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version")
    ap.add_argument("dir", type=pathlib.Path)
    ap.add_argument("--published", help="ISO 8601 UTC time (default: now)")
    a = ap.parse_args()
    published = a.published or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", published):
        fail(f"--published must look like 2026-01-31T12:00:00Z, got {published!r}")
    print(json.dumps(build(a.version, a.dir, published), indent=2))


if __name__ == "__main__":
    main()
