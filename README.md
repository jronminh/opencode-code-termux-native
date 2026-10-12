# opencode-code-termux-native

Run **opencode** natively on Termux/Android — no `proot-distro`, no chroot,
no emulation. It takes the community aarch64 **musl** build of opencode
(published by [C04-wq/opencode-termux](https://github.com/C04-wq/opencode-termux)),
patches its ELF interpreter to the musl loader shipped beside it, and wraps
launch so the musl runtime never leaks into the Bionic `bash`/`ripgrep` that
opencode spawns (the leak that breaks the stock npm launcher).

> Unofficial, community project — not affiliated with or endorsed by the
> opencode authors.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jronminh/opencode-code-termux-native/main/bootstrap.sh | bash
```

Or clone and run it yourself:

```sh
pkg install -y git
git clone https://github.com/jronminh/opencode-code-termux-native.git
cd opencode-code-termux-native
bash install.sh
```

Then open a new Termux session and run `opencode`.

## What it does

1. **Downloads and patches the musl build** — verifies its SHA-256 and patches
   the ELF interpreter to `~/.opencode/ld-musl-aarch64.so.1`.
2. **Installs a wrapper** — `$PREFIX/bin/opencode` execs the loader with
   `--library-path`, scoping the musl runtime to that single `exec` so nothing
   leaks into child processes.
3. **Turns off the autoupdater** — so opencode can't silently replace the
   patched binary with an unpatched, unrunnable one. Update deliberately with
   `termux-update-opencode`.
4. **Installs environment notes** — `environment.md` (merged into
   `~/.config/opencode/`) tells every session it's on a patched-musl/Termux
   setup.

## Uninstall

```sh
bash uninstall.sh          # remove the wiring, keep the app + libs
bash uninstall.sh --full   # also remove ~/.opencode/opencode-native + backups
```

## Requirements

- Android/Termux **aarch64**, Termux from F-Droid or GitHub (not Play Store).

## License

GPL-3.0 — see [LICENSE](LICENSE).
