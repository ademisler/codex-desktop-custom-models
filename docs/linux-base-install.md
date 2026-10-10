# Linux Base Install

This repository assumes you already have a working Codex Desktop app on Linux.
It does not replace Linux packaging projects. Use whichever base install path is
best for your distribution.

Known community options include:

- `codex-app-linux`, which launches a Linux build through npm/AUR packaging.
- `codex-desktop-linux`, which rebuilds the upstream desktop app into native
  Linux packages.
- Your own extracted Electron app directory.

Run the bootstrap check after your base app works:

```bash
./scripts/bootstrap.sh
```

If the base app is not in an auto-detected location, pass it explicitly:

```bash
CODEX_BASE_APP_DIR="$HOME/.local/opt/codex/codex-app" ./scripts/bootstrap.sh
```

## Required Base Files

The custom app creator expects a Linux Codex app directory with:

- `start.sh`
- `electron`
- `content/webview`
- `resources/app.asar`
- Chromium support files such as `chrome_100_percent.pak`, `resources.pak`, and
  `locales/`

The exact list can change with upstream releases. The script is conservative:
it links everything by default, then copies files that need app-specific
identity.

## Why This Repo Does Not Vendor Codex

Codex Desktop is not redistributed here. This project only contains scripts,
templates, and bridge code. You bring your own local Codex installation.
