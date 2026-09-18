---
name: termux-doctor
description: Diagnose and self-repair Claude Code's native Termux/Android install — the patched-ELF glibc-on-Bionic workaround from claude-code-termux-native. Use when claude/grep/bash/find misbehaves in this environment (segfault on launch, "bad ELF magic", "invalid ELF header", "cannot execute", grep/-G shared-library errors, LD_PRELOAD/LD_LIBRARY_PATH weirdness, patchelf/glibc/interpreter problems, "native binary not installed"), or before hand-editing anything under ~/.claude/claude-native/ or $PREFIX/bin/claude.
---

<!-- Installed and kept in sync by claude-code-termux-native's install.sh
     from skills/termux-doctor/SKILL.md in that repo. A future install.sh
     run overwrites this file whole — don't hand-edit it; fix the repo
     copy instead, then re-run install.sh. -->

# termux-doctor

## Rule 0 — verify yourself, don't treat this file as scripture

This file is a snapshot. Paths, versions, and structure may have changed
after any Termux upgrade, glibc upgrade, or claude update itself. BEFORE
concluding something is broken or deciding what to fix, run
`~/.claude/claude-native/doctor.sh` and trust the actual result over the
words here. If reality disagrees with this description, reality wins.

`doctor.sh` also takes `--json` (same checks, one JSON object, for scripting)
and `--fix` (runs the same locked self-heal block `autocheck.sh` runs on
every new shell — chmod, re-patch the interpreter, re-add
`DISABLE_AUTOUPDATER` — then the normal dump).

Minimum probe commands if you don't want to run the full script:

    uname -m                         # expected: aarch64
    echo "$PREFIX"; echo "$HOME"
    command -v claude; readlink -f "$(command -v claude)"
    file ~/.claude/claude-native/claude
    patchelf --print-interpreter ~/.claude/claude-native/claude
    ls -l "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
    env | grep -i '^LD_'

## Current install state (verify again, don't trust the text)

- Binary:      `~/.claude/claude-native/claude`   (patched via `patchelf --set-interpreter`)
- Interpreter: `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`
- Wrapper:     `$PREFIX/bin/claude`       (what actually runs when you type `claude`)
- The self-repair/update kit (binary, autocheck.sh, update.sh, doctor.sh,
  manifest.json, the lock/history files) lives at `~/.claude/claude-native/`.
- glibc libraries are supplied at runtime NOT via the `LD_LIBRARY_PATH`
  environment variable, but via the `--library-path` flag invoking the
  dynamic linker directly (see trap #1 — an env var is inherited by child
  processes, a command-line flag is not). Do not embed an rpath in the
  binary (the bun binary has an appended payload; rewriting section
  headers corrupts it).

The actual wrapper (`$PREFIX/bin/claude`) currently reads:

    #!/data/data/com.termux/files/usr/bin/bash
    unset LD_PRELOAD
    export TMPDIR="$HOME/.cache/claude-tmp"
    mkdir -p "$TMPDIR"
    export USE_BUILTIN_RIPGREP=0
    export DISABLE_AUTOUPDATER=1
    export CLAUDE_CODE_EXECPATH="$HOME/.claude/claude-native/claude"
    export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1
    if "$HOME/.claude/claude-native/claude" --version >/dev/null 2>&1; then
      exec "$HOME/.claude/claude-native/claude" "$@"
    else
      exec "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
        --library-path "$PREFIX/glibc/lib" \
        "$HOME/.claude/claude-native/claude" "$@"
    fi

Every line has a load-bearing reason:
- `unset LD_PRELOAD` — Termux preloads libtermux-exec (Bionic) by default.
  The glibc loader chokes on it with "invalid ELF header" and claude never
  starts.
- A writable `TMPDIR` — Android has no `/tmp`.
- `USE_BUILTIN_RIPGREP=0` — use Termux's own `rg`.
- `DISABLE_AUTOUPDATER=1` — blocks the built-in updater; see
  "Future-proofing" below.
- `CLAUDE_CODE_EXECPATH` — see trap #8. Without this, claude self-detects
  its execPath from `/proc/self/exe`, which breaks the built-in `grep`
  shell function it injects into every Bash-tool shell if that path ever
  resolves to something other than the claude binary itself.
- `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` — belt-and-suspenders for trap #9.
- Preferring to `exec` the patched binary **directly**, with the
  `ld-linux --library-path` form (trap #1) only as a fallback if a
  preflight `--version` check shows direct-exec doesn't work on this
  install — see trap #8. Direct exec only works because Termux's
  `ld.so.cache` already lists the glibc lib dir as a system search path.

## Traps encountered — symptom → cause → fix

1. Termux commands (mkdir, ls, and ESPECIALLY the bash that claude's own
   Bash tool spawns) die with "bad ELF magic: 2f2a2047" or
   "CANNOT LINK EXECUTABLE ... bash"
   → glibc's `LD_LIBRARY_PATH` was set via an environment variable (even
     `env LD_LIBRARY_PATH=... exec claude`), so it LEAKS into every child
     process claude spawns afterward — including the Bionic bash claude
     itself invokes for the Bash tool. The Bionic linker loads glibc's
     `libc.so` by mistake and chokes.
   → Root fix: don't set `LD_LIBRARY_PATH` via env. If you must invoke the
     linker explicitly, use `--library-path` on the command line — that
     only applies to that one exec, never leaks. After fixing, you MUST
     fully quit the currently running claude session (it already inherited
     the old env) and open a new one.
2. "Permission denied" / "cannot execute: Success" running the binary
   → binary is missing the execute bit after curl/patchelf. `chmod +x`.
     (The "Success" line is just a stale errno being misprinted — ignore it.)
3. grep/rg dies with "invalid ELF header" mid-session
   → Bionic's `LD_PRELOAD` leaked into a glibc process. Make sure
     `unset LD_PRELOAD`. Never write `env.LD_PRELOAD` into
     `~/.claude/settings.json`.
4. "cannot execute" / interpreter not found, or it points at
   `/lib/ld-linux-aarch64.so.1`
   → binary was never patched, OR an update overwrote it with an unpatched
     build. Run `patchelf --set-interpreter` again, then `chmod +x`
     (`autocheck.sh` does this automatically — see "Self-check + self-heal").
5. claude exits immediately with "native binary not installed"
   → hit the newer binary-distribution mechanism that has no android
     target. You need a patched `linux-arm64` build, not one installed via
     `npm`/`claude install`.
6. Segfault right after `patchelf`
   → some glibc binaries won't tolerate patchelf. Fallback: don't patch
     it, run it via `grun <binary>` instead (grun unsets `LD_PRELOAD` and
     sets the library path itself).
7. Write errors to `/tmp` / `EACCES` at runtime
   → `TMPDIR` isn't set or doesn't exist. Create it and point `TMPDIR` at
     a writable location.
8. Bare `grep` inside a Bash tool call fails with
   "-G: error while loading shared libraries: -G: cannot open shared
   object file" (real `command grep` and `rg` still work fine)
   → Claude Code injects an exported bash function named `grep` into every
     shell it spawns, which shadows real grep for most flag combos and
     instead does `exec -a ugrep "$CLAUDE_CODE_EXECPATH" -G --ignore-files
     ... "$@"` (a hidden ripgrep-like personality baked into the claude
     binary itself, dispatched via `argv[0]=ugrep`). If `CLAUDE_CODE_EXECPATH`
     ever points at the ld-linux interpreter instead of the claude binary
     (e.g. a wrapper that explicitly `exec`'d `ld-linux ... claude`, so the
     kernel recorded ld-linux — not claude — as the process's exe_file, and
     claude's own `process.execPath` read that back and overwrote the env
     var with it), the function ends up running the raw linker with
     grep-style flags, which it can't parse.
   → Root fix (already applied by the installed wrapper above): `exec` the
     patched binary directly, with no explicit `ld-linux` invocation — the
     kernel then records the binary itself as exe_file, so
     `process.execPath` resolves correctly and the re-exec preserves
     `argv[0]=ugrep` all the way through the kernel's automatic PT_INTERP
     dispatch to ld.so. Also export `CLAUDE_CODE_EXECPATH` explicitly as a
     backstop. As with trap #1, a currently-running session already
     inherited whatever was set at startup — fully quit and reopen for a
     fix here to take effect.
9. claude segfaults immediately on launch, no useful error
   → NOT a seccomp block. Bun's maintainer traced it via strace
     (github.com/oven-sh/bun/issues/32489): on kernels that report >=5.11,
     Bun's event loop attempts `epoll_pwait2` through glibc's generic
     `syscall()` wrapper — and in this patched-ELF/Termux-glibc-runner
     environment, that wrapper itself faults on a TLS access before the
     actual syscall instruction ever executes. strace on a real crash
     (OPPO CPH2499, Android 16, kernel 5.15.180) shows no
     epoll_pwait/epoll_pwait2 entry at all before the SIGSEGV.
   → FIXED upstream in oven-sh/bun#32490: raw inline asm for the syscall,
     an `-android` release-string gate, and a
     `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` env var that force-disables
     it. Whether a given install is at risk depends on the *bundled Bun
     version*, not just the kernel — check with
     `strings ~/.claude/claude-native/claude | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2`
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
     If a user still hits this crash despite the flag (old Claude Code
     version, flag string absent per `doctor.sh`), a real LD_PRELOAD shim
     is the fallback — github.com/gtbuchanan/claude-code-termux ships one.

## Future-proofing

- `DISABLE_AUTOUPDATER=1` must always be present in BOTH places: exported
  by the wrapper (`$PREFIX/bin/claude`) AND set in
  `~/.claude/settings.json`. The in-process updater is more stubborn than
  it looks: blocking one layer still lets it download an unpatched build
  on top of the patched one → claude dies next launch. `autocheck.sh`
  automatically re-adds the settings.json key if it finds it missing (see
  "Self-check + self-heal"); `doctor.sh` checks both places.
- Every write to `~/.claude/settings.json` (by `install.sh`, `autocheck.sh`,
  or `uninstall.sh`) backs up the current file to `settings.json.bak`
  first — a single rolling generation, same pattern as `claude.prev` for
  the binary. Restore by hand: `cp ~/.claude/settings.json.bak
  ~/.claude/settings.json`. `doctor.sh` reports whether a backup exists
  and when it was taken.
- If `termux-notification` is available (optional — `pkg install
  termux-api` plus the separate Termux:API app; NOT installed by
  `install.sh`), a real (non-`--check-only`) update failure and a
  repatch-frequency escalation each push a notification, so they aren't
  missed in a backgrounded tab. Silent no-op otherwise. `doctor.sh` reports
  whether this is wired up.
- Updating is NOT a manual step by default. `update.sh --check-only` runs
  automatically every time Termux opens and just reports whether a new
  version exists; `termux-update-claude` (no flag) does the actual
  download/verify/patch. You cannot hot-swap the binary of a currently
  running session — quit and reopen to pick up a new build.
- After EVERY Termux `pkg upgrade` or glibc bump: run `doctor.sh`. It now
  persists the glibc/patchelf versions it saw last time and flags drift
  automatically — if the loader path changed or glibc jumped,
  `patchelf --print-interpreter` may still match while the actual library
  underneath has drifted, so re-patch to be safe.
- The `manifest.json` structure isn't guaranteed stable. The arm64
  checksum key is currently inferred to be
  `.platforms["linux-arm64"].checksum` but this has NOT been confirmed
  with certainty. If `update.sh` reads it as null/empty, it stops itself
  and writes a full report — open that report, or open `manifest.json`
  yourself to see the real structure and fix the key in the repo's
  `scripts/update.sh`.

## Self-check + self-heal (autocheck.sh, runs every time Termux opens)

- `~/.bashrc` sources `~/.claude/claude-native/autocheck.sh` on every
  interactive shell. This script ONLY runs when actually opening Termux (a
  login shell reading `.bashrc`) — it does NOT run inside the bash that
  claude itself spawns for the Bash tool (non-interactive, doesn't read
  `.bashrc`), so it causes no slowdown or side effects inside a claude
  session.
- `autocheck.sh` self-heals (silent if there's nothing to fix):
    - defensively unsets `LD_PRELOAD`/`LD_LIBRARY_PATH`, `mkdir`'s `TMPDIR`
    - `chmod +x`'s the binary back if it lost its execute bit
    - re-runs `patchelf` on the interpreter if the binary was overwritten
      by an unpatched build (typically by the autoupdater) — no
      re-download needed, patches in place
    - re-adds `DISABLE_AUTOUPDATER=1` to settings.json if it went missing
    - warns (does NOT auto-fix) if the wrapper was changed back to setting
      `LD_LIBRARY_PATH` via an environment variable (trap #1 recurring) —
      this case must be fixed by hand, since auto-editing an executable
      wrapper script carries more risk than benefit
  It then calls `update.sh --check-only` — CHECK ONLY, it never
  auto-downloads or installs anything.
- **Locking**: the chmod/patchelf/settings-edit block runs inside a
  `flock` on `~/.claude/claude-native/.claude-native.lock`. `update.sh`'s
  own install step takes the SAME lock file, so two Termux tabs open at
  once can't stomp on each other.
- **Repatch-frequency escalation**: every re-patch appends a timestamp to
  `~/.claude/claude-native/.repatch-history` (trimmed to last 50). 2+
  re-patches within 24h escalates from a quiet fix notice to an explicit
  WARNING that `DISABLE_AUTOUPDATER` may not actually be holding, plus a
  Termux:API push notification if `termux-notification` is available.
- **Rollback**: `update.sh` copies the current binary/manifest to
  `claude.prev` / `manifest.json.prev` before installing a new version.
  `termux-update-claude --rollback` swaps `claude.prev` back into place
  (keeping the rejected build aside as `claude.rejected`, not deleted) and
  refuses cleanly if no backup exists.
- **termux-update-claude**: the dedicated command for the user to type by
  hand — both "manual check" and "confirm the update" (typing it IS the
  confirmation, no separate y/n prompt). No new version → "Already on the
  latest version". New version → downloads with live progress and
  automatic retry/resume (`curl --retry --retry-all-errors -C -`).
  `--rollback` reverts to the previous binary.
- `update.sh` has 2 modes: `--check-only` (silent unless a new version
  exists, in which case it prints one line pointing at
  `termux-update-claude` and downloads nothing) and no-flag (does the real
  work: download, verify SHA-256, patch, install — any failing step
  writes a full report to `update-fail-<timestamp>.log` and, if
  `termux-notification` is available, pushes a notification too;
  `--check-only` failures never notify, they're expected background noise
  on flaky networks).

## Golden rules for self-repair

- Always distinguish: is this command Bionic (Termux) or glibc (the
  patched claude binary)? Don't let a glibc env leak into a Bionic
  command, or vice versa.
- Read the real errno/message, don't get led astray by noise lines like
  "Success".
- When stuck, `grun` is the safe fallback.
- After fixing something: rerun `~/.claude/claude-native/doctor.sh`. If
  what you found is a real, reproducible gap in this setup (not specific
  to this one machine), it belongs as a fix in
  [claude-code-termux-native](https://github.com/jronminh/claude_code_termux_native)
  — a PR against its `scripts/*.sh` and `CLAUDE.md.template`/this skill
  helps the next install too.
