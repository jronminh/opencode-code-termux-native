# opencode-code-termux-native

Run **opencode** natively on Termux/Android — no `proot-distro`, no Ubuntu
chroot, no emulation layer. Uses the official aarch64 musl release with a
private Alpine musl runtime, then wires opencode into the
environment so it knows it's on a Bionic/aarch64 setup and can
self-diagnose failures (segfaults, invalid ELF, grep/ripgrep dying) instead of
guessing.

> Unofficial Termux integration — not affiliated with or endorsed by the
> OpenCode authors. `install.sh` downloads the official
> `opencode-linux-arm64-musl.tar.gz` release from
> [anomalyco/opencode](https://github.com/anomalyco/opencode), verifies its
> GitHub-published SHA-256, and invokes it through an explicit musl loader.

## Why this exists

- opencode publishes no `android-arm64`/Bionic build. The official Linux
  ARM64 build is musl-linked, so it needs a private musl loader and C++ runtime
  on Termux.
- The stock npm launcher exported `LD_PRELOAD`/`LD_LIBRARY_PATH`, which broke
  the Bionic `bash`/`ripgrep` that opencode itself spawns. This repo replaces
  it with a wrapper that scopes the library path to a single `exec`
  (`--library-path`), so nothing leaks into children.
- opencode's autoupdater would silently swap in an incompatible build. This repo
  disables it (`OPENCODE_DISABLE_AUTOUPDATE=1` + config) and provides a
  verified `termux-update-opencode` path instead, with rollback.

## Install

```sh
pkg install -y git
git clone https://github.com/jronminh/opencode-code-termux-native.git
cd opencode-code-termux-native
bash install.sh
```

Then run `opencode`.

## What install.sh does

1. Installs deps (`curl jq ripgrep tar coreutils file binutils ca-certificates ...`).
2. Downloads and SHA-256-verifies the official aarch64 musl build and the
   Alpine musl/libgcc/libstdc++ runtime, staging them under
   `~/.opencode/runtime/`.
3. Installs the `opencode` wrapper into `$PREFIX/bin` (loader
   `--library-path`, `OPENCODE_DISABLE_AUTOUPDATE=1`, `TMPDIR`).
4. Wires `autocheck.sh` into `~/.bashrc` — self-heal + update check on each new
   shell (opencode has no hook system).
5. Sets `"autoupdate": false` in `~/.config/opencode/opencode.jsonc` (previous
   version backed up).
6. Merges `environment.md.template` into `~/.config/opencode/environment.md`
   (wired in via `instructions`) and installs the `opencode-termux-doctor`
   skill.

## Commands

- `opencode` — the official binary, via the private musl runtime wrapper.
- `termux-update-opencode` — download → verify → stage runtime → install, with rollback.
- `termux-opencode-features status|enable|disable` — opt-in features.
- `termux-opencode-job` — headless `opencode run` on Android's JobScheduler
  (not plain cron, which Android kills when the screen locks).

## Extra features (opt-in)

- **adb-bridge** — see and drive the *entire* Android screen (screenshots,
  exact-coordinate `uiautomator` dumps, tap/swipe, full-system logcat) through
  [termux-adb-bridge](https://github.com/jronminh/termux-adb-bridge)'s
  shell-UID daemon (`dsh`) — no Shizuku, no `adb`. Security-sensitive
  (commands run at the `shell` UID). `termux-opencode-features enable
  adb-bridge` (requires termux-adb-bridge installed and its daemon running).
- **notifications** — n/a: opencode has no settings.json hook system.

## Layout

```
~/.opencode/opencode                  # official ARM64 musl binary
~/.opencode/runtime/                   # loader + musl/libstdc++/libgcc
~/.opencode/opencode-native/          # doctor.sh, autocheck.sh, update.sh, jobs
~/.config/opencode/opencode.jsonc     # global config (autoupdate off)
~/.config/opencode/environment.md     # managed notes (begin/end markers)
~/.config/opencode/skills/            # opencode-termux-doctor, adb-bridge
$PREFIX/bin/opencode                  # wrapper
$PREFIX/bin/termux-{update-,}opencode-*
```

## Doctor / troubleshooting

`bash ~/.opencode/opencode-native/doctor.sh` — checks the interpreter, leaked
`LD_*`, autoupdater state, Termux freshness, disk space, and the adb-bridge
daemon.

If opencode segfaults on launch, reports `invalid ELF header`, has grep/ripgrep
dying mid-tool-call, or an update breaks it: invoke the `opencode-termux-doctor`
skill (or run `doctor.sh`) **before** hand-editing anything under
`~/.opencode/opencode-native/` or `$PREFIX/bin/opencode`.

## Requirements

- Android/Termux **aarch64**, Termux from F-Droid or GitHub (not Play Store).
- ~200 MB for the official binary plus the musl runtime libs.

## Credits

Built with AI assistance from **Claude** (Anthropic) and **DeepSeek**
(`deepseek-v4-flash`, via opencode). All design decisions, review, and testing
are the maintainer's.

## License

GPL-3.0 — see [LICENSE](LICENSE).
