---
name: opencode-termux-doctor
description: Diagnose and self-repair OpenCode's native Termux/Android install — the patched-ELF musl-on-Bionic setup from opencode-code-termux-native. Use when opencode/grep/bash/find misbehaves in this environment (segfault on launch, "invalid ELF header", "cannot execute", grep/-G shared-library errors, bash/ripgrep hanging or dying mid-tool-call, LD_PRELOAD/LD_LIBRARY_PATH weirdness, patchelf/loader/interpreter problems, "is this install even patched?"), or before hand-editing anything under ~/.opencode/opencode-native/ or $PREFIX/bin/opencode.
---

<!-- Installed and kept in sync by opencode-code-termux-native's install.sh
     from skills/opencode-termux-doctor/SKILL.md in that repo. A future
     install.sh run overwrites this file whole — don't hand-edit it; fix
     the repo copy instead, then re-run install.sh. -->

# opencode-termux-doctor

## Rule 0 — verify yourself, don't treat this file as scripture

This file is a snapshot. Paths, versions, and structure may have changed
after any Termux upgrade, patchelf bump, or opencode update itself. BEFORE
concluding something is broken or deciding what to fix, run
`~/.opencode/opencode-native/doctor.sh` and trust the actual result over
the words here. If reality disagrees with this description, reality wins.

`doctor.sh` also takes `--json` (same checks, one JSON object, for scripting)
and `--fix` (runs the same locked self-heal block `autocheck.sh` runs on
every new Termux shell — chmod, re-patch the interpreter, re-add
`OPENCODE_DISABLE_AUTOUPDATE` — then the normal dump).

Minimum probe commands if you don't want to run the full script:

    uname -m                          # expected: aarch64
    echo "$PREFIX"; echo "$HOME"
    readlink -f "$(command -v opencode)"
    file ~/.opencode/opencode
    patchelf --print-interpreter ~/.opencode/opencode
    ls -l ~/.opencode/ld-musl-aarch64.so.1 ~/.opencode/libc.musl-aarch64.so.1
    env | grep -i '^LD_'              # must be empty for a clean launch

## Current install state (verify again, don't trust the text)

- Binary:      `~/.opencode/opencode`      (patched via `patchelf --set-interpreter`)
- Interpreter: `~/.opencode/ld-musl-aarch64.so.1` (musl loader, NOT glibc)
- Runtime libs (beside the loader): `libc.musl-aarch64.so.1`,
  `libstdc++.so.6` (→ `libstdc++.so.6.0.33`), `libgcc_s.so.1`
- Wrapper:     `$PREFIX/bin/opencode`  (what actually runs when you type `opencode`)
- The self-repair/update kit (autocheck.sh, update.sh, doctor.sh, the
  lock/history files, docs) lives at `~/.opencode/opencode-native/`.
- musl libraries are supplied at runtime NOT via the `LD_PRELOAD` /
  `LD_LIBRARY_PATH` environment variables, but via the `--library-path`
  flag invoking the musl loader directly (trap #1 — an env var is inherited
  by child processes, a command-line flag is not). Do not embed an rpath in
  the binary (the bun binary has an appended payload; rewriting section
  headers corrupts it).

The actual wrapper (`$PREFIX/bin/opencode`) currently reads:

    #!/data/data/com.termux/files/usr/bin/bash
    unset LD_PRELOAD LD_LIBRARY_PATH
    OPENCODE_DIR="$HOME/.opencode"
    BIN="$OPENCODE_DIR/opencode"
    LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"
    export TMPDIR="${OPENCODE_TMPDIR:-$HOME/.cache/opencode-tmp}"
    mkdir -p "$TMPDIR"
    export OPENCODE_DISABLE_AUTOUPDATE=1
    export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
    export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1
    ...
    exec "$LD" --library-path "$OPENCODE_DIR" "$BIN" "$@"

Every line has a load-bearing reason:
- `unset LD_PRELOAD LD_LIBRARY_PATH` — Termux preloads libtermux-exec
  (Bionic) by default; that (plus the stock npm launcher exporting these)
  is exactly the leak that breaks Bionic bash/rg. A leaked `LD_PRELOAD`
  makes the musl loader choke on a Bionic library ("invalid ELF header")
  and opencode never starts.
- A writable `TMPDIR` — Android has no `/tmp`.
- `OPENCODE_DISABLE_AUTOUPDATE=1` — blocks opencode's built-in updater; see
  "Future-proofing" below.
- `SSL_CERT_FILE` — the musl build has no CA bundle of its own; Termux's
  is the one to use.
- `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` — belt-and-suspenders for trap #8.
- The loader `--library-path` exec is **mandatory**: direct exec of `$BIN`
  fails on Bionic ("Error loading shared library libstdc++.so.6" /
  "symbol not found") because there's no `ld.so.cache` entry for these
  musl libs. Scoping the library search via the flag means the search
  applies to that one exec only — it can never leak into opencode's
  children, which is the exact opposite of the stock npm launcher.

## Traps encountered — symptom → cause → fix

1. The Bionic bash that opencode's Bash tool spawns hangs or dies with
   "bad ELF magic", "CANNOT LINK EXECUTABLE ... bash", or ripgrep dies
   with "invalid ELF header"
   → `LD_LIBRARY_PATH` (or `LD_PRELOAD`) was set via an environment
     variable — the stock opencode-termux npm launcher does exactly this
     — so it LEAKS into every child process opencode spawns afterward,
     including Bionic bash/rg. The Bionic linker loads the musl
     `libc.musl` / glibc lib by mistake and chokes.
   → Root fix: don't set `LD_LIBRARY_PATH`/`LD_PRELOAD` via env. Invoke the
     loader explicitly with `--library-path` on the command line — that
     only applies to that one exec, never leaks. After fixing, you MUST
     fully quit the currently running opencode session (it already
     inherited the old env) and open a new one.
2. "Permission denied" / "cannot execute: Success" running the binary
   → binary is missing the execute bit after curl/patchelf. `chmod +x`.
     (The "Success" line is just a stale errno being misprinted — ignore it.)
3. "invalid ELF header" launching opencode itself
   → Bionic's `LD_PRELOAD` (libtermux-exec.so) leaked into the musl loader.
     Ensure the wrapper `unset LD_PRELOAD`. Never set it in the raw
     `exec` environment.
4. "cannot execute" / interpreter not found, or interpreter shows
   `/lib/ld-musl-aarch64.so.1` or empty
   → binary was never patched, OR opencode's in-process autoupdater
     overwrote it with an unpatched build. Run `patchelf --set-interpreter
     ~/.opencode/ld-musl-aarch64.so.1 ~/.opencode/opencode` again, then
     `chmod +x` (`autocheck.sh` does this automatically — see
     "Self-check + self-heal").
5. "Error loading shared library ... " or "symbol not found" on launch
   → the musl libs aren't findable: direct exec without the loader
     `--library-path` form, or the libs were moved/removed from
     `~/.opencode/`. Re-run `install.sh` to restore them (update.sh
     verifies all six REQUIRED_FILES before it will proceed).
6. Write errors to `/tmp` / `EACCES` at runtime
   → `TMPDIR` isn't set or doesn't exist. Create it and point `TMPDIR` at
     a writable location.
7. Segfault right after `patchelf`
   → Bun binaries tolerate `patchelf --set-interpreter` (the official
     opencode-termux installer does exactly this), but a segfault right
     after a manual patch usually means the interpreter got set to
     something that isn't the companion loader, or the patch target was a
     stale/partial file. Restore from `opencode.prev` and re-patch with
     the exact `$LD` path.
8. opencode segfaults immediately on launch, no useful error
   → NOT a seccomp block. Bun's maintainer traced it via strace
     (github.com/oven-sh/bun/issues/32489): on kernels that report >=5.11,
     Bun's event loop attempts `epoll_pwait2` through glibc's generic
     `syscall()` wrapper — and in this patched-ELF/Termux environment,
     that wrapper itself faults on a TLS access before the actual syscall
     instruction ever executes. Real crash seen: OPPO CPH2499, Android 16,
     kernel 5.15.180, no epoll_pwait/pwait2 entry before SIGSEGV.
   → FIXED upstream in oven-sh/bun#32490: raw inline asm for the syscall,
     an `-android` release-string gate, and a
     `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` env var that force-disables
     it. Whether a given install is at risk depends on the *bundled Bun
     version*, not just the kernel — check with
     `strings ~/.opencode/opencode | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2`
     (`doctor.sh` does this automatically).
   → Critical nuance: kernel version is fixed at the device's ORIGINAL
     manufacture (Android's KMI ties vendor kernel modules — GPU, camera,
     modem drivers — to one specific kernel build; rebasing to a newer
     kernel means recertifying all of them, which vendors avoid). An OS
     upgrade via OTA does NOT change the kernel. A phone can show
     "Android 16" in Settings while still running the exact kernel it
     shipped with on Android 12 years earlier. Never infer this risk from
     the Android version shown in Settings — always check the real kernel
     with `uname -r` (risk zone: 5.11+) or `doctor.sh`.
   → Belt-and-suspenders: the wrapper also exports
     `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` unconditionally — harmless
     on a patched Bun (flag already forces the same safe path) and a real
     safety net on any older bundled Bun that predates the upstream fix.

## Future-proofing

- The autoupdater must be off in BOTH places: `OPENCODE_DISABLE_AUTOUPDATE=1`
  exported by the wrapper (`$PREFIX/bin/opencode`) AND `"autoupdate": false`
  in `~/.config/opencode/opencode.jsonc`. The in-process updater is more
  stubborn than it looks: blocking one layer still lets it download an
  unpatched build on top of the patched one → opencode dies next launch.
  `autocheck.sh` automatically re-adds both if they go missing (see
  "Self-check + self-heal"); `doctor.sh` checks both places.
- Every write to `~/.config/opencode/opencode.jsonc` (by `install.sh`,
  `autocheck.sh`, or `uninstall.sh`) backs up the current file to
  `opencode.json.bak` first — a single rolling generation. Restore by
  hand: `cp ~/.config/opencode/opencode.jsonc.bak
  ~/.config/opencode/opencode.jsonc`. `doctor.sh` reports whether a backup
  exists and when it was taken.
- If `termux-notification` is available (optional — `pkg install
  termux-api` plus the separate Termux:API app; NOT installed by
  `install.sh`), a real (non-`--check-only`) update failure and a
  repatch-frequency escalation each push a notification, so they aren't
  missed in a backgrounded tab. Silent no-op otherwise. `doctor.sh` reports
  whether this is wired up.
- Updating is NOT a manual step by default. `update.sh --check-only` runs
  automatically every time Termux opens and just reports whether a new
  version exists; `termux-update-opencode` (no flag) does the actual
  download/verify/patch. You cannot hot-swap the binary of a currently
  running session — quit and reopen to pick up a new build.
- After EVERY Termux `pkg upgrade` or patchelf bump: run `doctor.sh`. It
  now persists the musl-loader-sha/patchelf versions it saw last time and
  flags drift automatically.
- The distributed checksum metadata structure (npm package
  `opencode-termux`'s `release-checksums.json`) isn't guaranteed stable.
  `update.sh` reads `.archiveSha256` there (verified against `.version`),
  and if it reads either as null/empty it stops itself and writes a full
  report — open that report to see the real structure and fix the key in
  the repo's `scripts/update.sh`.

## Self-check + self-heal (autocheck.sh, runs every time Termux opens)

- `~/.bashrc` sources `~/.opencode/opencode-native/autocheck.sh` on every
  interactive shell. This script ONLY runs when actually opening Termux (a
  login shell reading `.bashrc`) — it does NOT run inside the bash that
  opencode itself spawns for the Bash tool (non-interactive, doesn't read
  `.bashrc`), so it causes no slowdown or side effects inside an opencode
  session.
- `autocheck.sh` self-heals (silent if there's nothing to fix):
    - defensively unsets `LD_PRELOAD`/`LD_LIBRARY_PATH`, `mkdir`'s `TMPDIR`
    - `chmod +x`'s the binary back if it lost its execute bit
    - re-runs `patchelf` on the interpreter if the binary was overwritten
      by an unpatched build (typically by the autoupdater) — no
      re-download needed, patches in place
    - re-adds `OPENCODE_DISABLE_AUTOUPDATE=1` to the wrapper and
      `"autoupdate": false` to the global opencode.json if either went
      missing
    - warns (does NOT auto-fix) if the wrapper was changed back to setting
      `LD_LIBRARY_PATH` via an environment variable (trap #1 recurring) —
      this case must be fixed by hand, since auto-editing an executable
      wrapper script carries more risk than benefit
  It then calls `update.sh --check-only` — CHECK ONLY, it never
  auto-downloads or installs anything.
- **Locking**: the chmod/patchelf/config-edit block runs inside a `flock`
  on `~/.opencode/opencode-native/.opencode-native.lock`. `update.sh`'s
  own install step takes the SAME lock file, so two Termux tabs open at
  once can't stomp on each other.
- **Repatch-frequency escalation**: every re-patch appends a timestamp to
  `~/.opencode/opencode-native/.repatch-history` (trimmed to last 50). 2+
  re-patches within 24h escalates from a quiet fix notice to an explicit
  WARNING that the autoupdater may not actually be holding, plus a
  Termux:API push notification if `termux-notification` is available.
- **Rollback**: `update.sh` copies the current binary/version-marker to
  `opencode.prev` / `.opencode-termux-version.prev` before installing a
  new version. `termux-update-opencode --rollback` swaps `opencode.prev`
  back into place (keeping the rejected build aside as `opencode.rejected`,
  not deleted) and refuses cleanly if no backup exists.
- **termux-update-opencode**: the dedicated command for the user to type by
  hand — both "manual check" and "confirm the update" (typing it IS the
  confirmation, no separate y/n prompt). No new version → "Already on the
  latest version". New version → downloads with live progress and
  automatic retry/resume (`curl --retry --retry-all-errors -C -`).
  `--rollback` reverts to the previous binary.
- `update.sh` has 2 modes: `--check-only` (silent unless a new version
  exists, in which case it prints one line pointing at
  `termux-update-opencode` and downloads nothing) and no-flag (does the real
  work: download, verify SHA-256, patch, install — any failing step writes
  a full report to `update-fail-<timestamp>.log` and, if
  `termux-notification` is available, pushes a notification too;
  `--check-only` failures never notify, they're expected background noise
  on flaky networks).

## Golden rules for self-repair

- Always distinguish: is this command Bionic (Termux) or musl (the patched
  opencode binary)? Don't let a musl env leak into a Bionic command, or
  vice versa.
- Read the real errno/message, don't get led astray by noise lines like
  "Success".
- When stuck, invoke the binary manually with the same loader form the
  wrapper uses (loader + `--library-path`) — that is always the safe
  fallback that sidesteps every env leak category at once.
- After fixing something: rerun `~/.opencode/opencode-native/doctor.sh`. If
  what you found is a real, reproducible gap in this setup (not specific
  to this one machine), it belongs as a fix in
  [opencode-code-termux-native](https://github.com/C04-wq/opencode-code-termux-native)
  — a PR against its `scripts/*.sh` and `environment.md.template`/this
  skill helps the next install too.