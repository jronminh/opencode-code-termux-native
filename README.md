# opencode-code-termux-native

Run **opencode** natively on Termux/Android — no `proot-distro`, no Ubuntu
chroot, no emulation layer. Patches the community aarch64 musl build so it
links against Termux's own musl loader, then wraps launch so the musl
runtime never leaks into the Bionic children opencode spawns.

> Unofficial, community project — not affiliated with or endorsed by the
> opencode authors. Ships no binary: `install.sh` downloads the aarch64 musl
> build from [C04-wq/opencode-termux](https://github.com/C04-wq/opencode-termux)
> releases (version + SHA-256 taken from its npm `release-checksums.json`) and
> patches it locally.

## What it does

1. **Downloads and patches the musl build** — fetches the aarch64 build,
   verifies its SHA-256, and patches the ELF interpreter to the musl loader
   that ships beside it (`~/.opencode/ld-musl-aarch64.so.1`).
2. **Installs a wrapper** — `$PREFIX/bin/opencode` execs the loader with
   `--library-path`, scoping the musl runtime to that single `exec` so it can't
   leak into the Bionic `bash`/`ripgrep` opencode spawns (the leak that breaks
   the stock opencode-termux npm launcher).
3. **Disables the autoupdater** — `OPENCODE_DISABLE_AUTOUPDATE=1` in the
   wrapper plus `"autoupdate": false` in `~/.config/opencode/opencode.jsonc`,
   so opencode can't silently swap in an unpatched build.
4. **Installs environment notes** — merges `environment.md.template` into
   `~/.config/opencode/environment.md` inside begin/end markers, and points
   opencode's global `instructions` at it, so every session knows it's on a
   patched-musl/Termux setup.

## Install

One line:

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

Then run `opencode`.

## Commands

- `opencode` — the patched binary, via the wrapper.
- `termux-update-opencode` — download → verify → patch → install.

## Layout

```
~/.opencode/opencode                        # patched binary
~/.opencode/ld-musl-aarch64.so.1            # + libc/libstdc++/libgcc beside it
~/.opencode/opencode-native/download.sh     # download + SHA-256 verify only
~/.opencode/opencode-native/install.sh      # extract + patch + smoke test + install
~/.opencode/opencode-native/lib.sh          # shared step/banner helpers
~/.opencode/opencode-native/environment.md.template  # managed env-notes source
~/.config/opencode/opencode.jsonc           # global config (autoupdate off)
~/.config/opencode/environment.md           # managed notes (begin/end markers)
$PREFIX/bin/opencode                        # wrapper
$PREFIX/bin/termux-update-opencode          # update command (re-runs install.sh)
```

## Uninstall

```sh
bash uninstall.sh          # remove the wrapper + config edit, keep app + libs
bash uninstall.sh --full   # also remove ~/.opencode/opencode-native + backups
```

## Requirements

- Android/Termux **aarch64**, Termux from F-Droid or GitHub (not Play Store).
- ~200 MB for the patched binary plus the musl runtime libs.

## License

GPL-3.0 — see [LICENSE](LICENSE).
