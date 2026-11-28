<img src="assets/icon.svg" width="64" height="64" alt="">

# mac-gaming

Created in [T3 Code](https://t3.codes).

- **Download:** [latest release](https://github.com/wezn/mac-gaming/releases/latest). How to install it (and approve it with
  Open Anyway): [docs/INSTALL.md](docs/INSTALL.md). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).
- [`launcher/`](launcher/README.md): `mgx`, the command-line launcher (Swift), and the MGCore library behind it.
- [`scripts/build-wine.sh`](scripts/build-wine.sh): builds CrossOver's Wine for Apple Silicon (run in CI by `build-wine.yml`).

## License

The code in this repository is licensed under the [Apache License 2.0](LICENSE).
Third-party components keep their own licenses (Wine and the CrossOver sources are
LGPL-2.1-or-later, DXMT is MIT, DXVK-macOS is zlib, MoltenVK is Apache-2.0, and more): see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships in the app and with `mgx`
(`mgx licenses`).
