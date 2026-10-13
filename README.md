# opencode-code-termux-native

Install the official OpenCode ARM64 musl release on Termux/Android without
`proot-distro`, chroot, or an emulation layer.

The installer downloads:

- the official `opencode-linux-arm64-musl.tar.gz` release from
  `anomalyco/opencode`, verified with the GitHub-published SHA-256;
- the matching musl, libgcc, and libstdc++ runtime objects from Alpine ARM64.

It then runs OpenCode through the musl loader with a private
`--library-path`, so musl paths do not leak into Termux's Bionic shell tools.

## Install

One-line install:

```sh
curl -fsSL https://raw.githubusercontent.com/jronminh/opencode-code-termux-native/main/install.sh | bash
```

Or clone and run locally:

```sh
bash install.sh
```

Run `install.sh` again to update. It is the only installer/update path.

## Uninstall

```sh
bash uninstall.sh
```

This removes the OpenCode binary, private runtime, generated wrapper, and the
installer's `autoupdate` setting. It does not remove unrelated user config.

## Layout

```text
~/.opencode/opencode          # official ARM64 musl binary
~/.opencode/runtime/          # musl loader + libc/libgcc/libstdc++
$PREFIX/bin/opencode          # generated loader wrapper
```

The wrapper is generated inline by `install.sh`; there are no staged updater,
doctor, autocheck, or background scripts.

## Requirements

- Termux on **aarch64** Android.
- Termux from F-Droid or GitHub.
- Network access to GitHub and the Alpine mirror.

## License

GPL-3.0 — see [LICENSE](LICENSE).
