# claude-code-termux-native

[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android%20aarch64-3DDC84)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)

**Run Claude Code natively on Termux/Android** — no `proot-distro`, no Ubuntu chroot, no emulation layer. Patches Claude Code's official `linux-arm64` binary to link against **Termux's own glibc** instead of Android's Bionic libc, and wires Claude Code itself into the environment — injecting notes into `~/.claude/CLAUDE.md` and installing a `termux-doctor` skill — so Claude knows it's on a patched Bionic/aarch64 setup and can self-diagnose failures (segfaults, bad ELF errors, patchelf weirdness, ...) instead of guessing blind. Updates safely too: a verified update/rollback path plus self-healing checks keep the patch from ever getting silently overwritten by a broken build.

> Unofficial, community project — not affiliated with or endorsed by Anthropic. Ships no binary: `install.sh` downloads it at install time from Anthropic's own `downloads.claude.ai`, the same endpoint the official installer uses, and verifies its SHA-256 against Anthropic's manifest before ever running it.

![install.sh running in Termux, all 8 steps completing successfully](assets/demo.gif)

## Why this exists

Anthropic ships `linux-arm64`, not `android-arm64`. Termux runs on Bionic libc, which that binary can't link against — but Termux also ships a real glibc (`glibc-repo`/`glibc-runner`) built for exactly this case.

The fix: `patchelf --set-interpreter` the binary to Termux's `ld-linux-aarch64.so.1`, then invoke it so it picks up Termux's glibc **without leaking that glibc environment into the Bionic processes Claude Code itself spawns** (its own Bash tool, `rg`, etc.). That constraint drives most of this repo's complexity — see [Troubleshooting](#troubleshooting).

One catch: Claude Code's built-in autoupdater silently swaps in a fresh, **unpatched** `linux-arm64` binary — which would eventually break `claude` on Bionic with no warning (Troubleshooting #4). This repo disables it (`DISABLE_AUTOUPDATER=1`) and replaces it with `termux-update-claude`: download → verify checksum against Anthropic's manifest → patch → install, so a working binary is never swapped for a broken one. `autocheck.sh` backs this up on every new shell, silently re-patching and re-disabling the autoupdater if anything ever slips through.

## Install

One line:

```sh
curl -fsSL https://raw.githubusercontent.com/jronminh/claude_code_termux_native/main/bootstrap.sh | bash
```

`bootstrap.sh` clones this repo to `~/claude-code-termux-native` (or fast-forwards an existing clone) and runs `install.sh` from it — nothing more. Read it before piping it into `bash` if you'd rather not run a remote script blind; it's under 30 lines.

Or clone it yourself first:

```sh
git clone https://github.com/jronminh/claude_code_termux_native.git ~/claude-code-termux-native
cd ~/claude-code-termux-native
bash install.sh
```

Both paths are idempotent — safe to re-run any time, e.g. after a Termux/glibc upgrade. Add `--with-notifications` and/or `--with-adb-bridge` to also turn on those two opt-in features (see [Extra features](#extra-features-beyond-a-bare-install)) right from the first install. Via the one-liner: `curl -fsSL .../bootstrap.sh | bash -s -- --with-notifications --with-adb-bridge`.

These flags only matter at first install — **to turn either one on or off later, don't re-run `install.sh`.** Use the dedicated `termux-claude-features` command instead (installed by `install.sh` either way):

```sh
termux-claude-features status                    # what's on/off right now
termux-claude-features enable  adb-bridge         # or: notifications
termux-claude-features disable adb-bridge         # or: notifications
```

This is the one thing `install.sh --with-X` and `uninstall.sh` don't cover well on their own: `install.sh` only ever *adds*, and short of `uninstall.sh` (which removes the entire setup, not just one feature), there was no way to turn a single feature back off. `termux-claude-features` is a small, standalone command exactly for that — see [Extra features](#extra-features-beyond-a-bare-install) for what each feature does.

Then open a **new** Termux session (or `exec bash`) and run:

```sh
claude
```

### What `install.sh` does

1. Checks you're on `aarch64` Termux.
2. Installs/upgrades `glibc-repo`, `glibc`, `patchelf`, `jq`, `curl`, `ripgrep`, `coreutils`.
3. Stages `autocheck.sh` / `update.sh` / `doctor.sh` / `session-hooks.sh` / `adb-bridge.sh` / `feature-hooks.sh` / `claude-features.sh` into `~/.claude/claude-native/` (`session-hooks.sh`/`adb-bridge.sh` are only *wired up* opt-in — see steps 12–13 below — but always staged, along with the adb-bridge skill source under `skill-sources/` and this repo's own [`docs/`](docs/) under `docs/`, so `termux-claude-features enable ...` can turn either feature on later, and Claude can read the architecture doc, without a re-download or the repo checkout).
4. Runs `update.sh` to download, verify, patch, and install the `claude` binary — the same path every later update uses.
5. Installs `claude` and `termux-update-claude` into `$PREFIX/bin`.
6. Hooks `autocheck.sh` into `~/.bashrc` (self-heal + silent update-check on every new shell).
7. Sets `DISABLE_AUTOUPDATER=1` in `~/.claude/settings.json` so Claude Code's built-in autoupdater can never silently drop in an unpatched binary (see "Why this exists" above); `termux-update-claude` replaces it as the update path.
8. Wires `doctor.sh` into a `SessionStart` hook — runs automatically at the start of every session, silent when clean, speaks up only on a real problem. Upserted via a marker comment, so later `install.sh` runs replace just this entry and leave any other hooks you've set up alone.
9. Merges [`CLAUDE.md.template`](CLAUDE.md.template) into your global `~/.claude/CLAUDE.md`, between `<!-- claude-code-termux-native:begin/end -->` markers, so claude recognizes this environment from the start of every session. Appends if you have your own content there; updates in place (never duplicates) on a later install. `uninstall.sh` removes just this section.
10. Installs the [`termux-doctor`](skills/termux-doctor/SKILL.md) skill to `~/.claude/skills/termux-doctor/`. The CLAUDE.md pointer tells claude to invoke it on any symptom from this setup (segfaults, bad ELF errors, patchelf weirdness, ...) instead of guessing — the full trap list and self-repair playbook load only when actually relevant.
11. Merges [`keybindings.json.template`](keybindings.json.template) into your `~/.claude/keybindings.json` — see [Extra features](#extra-features-beyond-a-bare-install) for what it rebinds and why.
12. With `--with-notifications`: wires `session-hooks.sh` into the `UserPromptSubmit`/`Stop`/`Notification` hooks (per-turn wake-lock + Termux:API notifications) — see [Extra features](#extra-features-beyond-a-bare-install). Skipped by default; toggle it later with `termux-claude-features` instead of re-running install.sh (see step 14).
13. With `--with-adb-bridge`: installs the [`adb-bridge`](skills/adb-bridge/SKILL.md) skill and wires a `Stop` hook that reminds you if a wireless ADB device is still connected when a turn ends — see [Extra features](#extra-features-beyond-a-bare-install). Skipped by default (security-sensitive); toggle it later with `termux-claude-features` instead of re-running install.sh (see step 14).
14. Installs `termux-claude-features` into `$PREFIX/bin` (always, regardless of the two flags above) — the dedicated command for turning steps 12/13's features on or off *after* install, without re-running `install.sh` or reaching for `uninstall.sh`. See [Extra features](#extra-features-beyond-a-bare-install).

## Migrating from a plain npm install

Before v2.1.113, Claude Code ran on Termux via a plain `npm install -g @anthropic-ai/claude-code` — a pure JS/Node path that needed no ELF patching at all. Anthropic dropped that fallback at v2.1.113+, requiring the native `linux-arm64` binary this repo exists to patch (see "Why this exists" above, and [anthropics/claude-code#50270](https://github.com/anthropics/claude-code/issues/50270)). If you're still on that old npm install, `migrate.sh` gets you onto the patched-native path:

```sh
bash migrate.sh                       # detect + back up the old install, then install.sh
bash migrate.sh --remove-npm-install  # also npm-uninstall the old package once backed up
bash migrate.sh --yes                 # skip the confirmation prompt
```

It detects the old install (a Node-shebang script, corroborated via `npm ls -g` when possible), renames it aside (`claude.pre-migrate-native.<timestamp>` — never deleted, trivially reversible), then hands off to `install.sh` for the actual native setup. `~/.claude/` (settings.json, session transcripts, CLAUDE.md, auth) is never touched by `migrate.sh` itself — only by `install.sh`'s own idempotent merges, exactly as they already behave against a populated directory. If it finds something it can't confidently classify (a different fork's patched binary, an unrecognized file), it prints what it found and does nothing — never guesses.

If you're not on the old npm path, running `migrate.sh` is a safe no-op — it recognizes this repo's own install and tells you there's nothing to do; run `install.sh` directly instead.

## Layout after install

```
~/.claude/claude-native/
  claude              # patched linux-arm64 binary
  manifest.json        # from Anthropic, used to verify checksums on update
  autocheck.sh          # self-heal, runs on every new Termux shell via .bashrc
  update.sh             # download/verify/patch/install + rollback
  doctor.sh             # diagnostic dump — run this first when something's broken
  session-hooks.sh      # optional Termux:API hooks (wake-lock + battery-aware notifications), only wired with --with-notifications
  adb-bridge.sh          # optional wireless-ADB screen/input/log bridge, only wired with --with-adb-bridge
  feature-hooks.sh       # shared enable/disable logic for notifications + adb-bridge, used by install.sh, uninstall.sh, AND termux-claude-features
  claude-features.sh     # backs the `termux-claude-features` command — toggle an opt-in feature without re-running install.sh/uninstall.sh
  skill-sources/adb-bridge/SKILL.md  # staged copy so `termux-claude-features enable adb-bridge` works without the repo checkout
  docs/*.md               # this repo's own reference docs — architecture map, Claude Code hooks reference, Termux:API survey, keybindings rationale (see docs/ in the repo)
  claude-job-runner.sh   # invoked by Android's JobScheduler for a scheduled `termux-claude-job`
  jobs/                  # one <name>.json (definition) + <name>.sh (stub JobScheduler target) + <name>.log per scheduled job
  .claude-native.lock    # flock used by autocheck.sh and update.sh so they never race
  .repatch-history       # timestamps of automatic re-patches (see below)
  .last-claude-version   # last two `claude --version` strings seen by doctor.sh (previous, current) — powers update recognition at session start
  .epoll-fix-cache       # "1"/"0" — does the installed build carry the trap #9 fix? refreshed by update.sh, read by the wrapper on every launch
  .pinned-version        # present only if you've run --pin — the version termux-update-claude tracks instead of stable

$PREFIX/bin/claude               # wrapper — what actually runs when you type `claude`
$PREFIX/bin/termux-update-claude # manual update/rollback command
$PREFIX/bin/termux-claude-job    # schedule/list/remove/run headless `claude -p` jobs via Android's JobScheduler
$PREFIX/bin/termux-claude-features  # status/enable/disable for notifications + adb-bridge, without re-running install.sh

~/.claude/CLAUDE.md              # our section lives inside begin/end markers; rest of the file is yours
~/.claude/skills/termux-doctor/SKILL.md   # full trap list + self-repair playbook, invoked on demand
~/.claude/skills/adb-bridge/SKILL.md      # wireless-ADB screen/input/log bridge, only installed with --with-adb-bridge
~/.claude/keybindings.json        # our rebinds merged in by value (no comment syntax to hang markers off), tracked via claude-native/.keybindings-managed.json
```

To change how any of this works, edit `scripts/` **in this repo** and re-run `install.sh` — don't hand-edit the installed copies under `~/.claude/claude-native/`; a future re-run overwrites them silently.

## Extra features (beyond a bare install)

- **Self-heal on every new shell** (`autocheck.sh`): fixes the execute bit, re-patches the interpreter if an unpatched build overwrote it, re-adds `DISABLE_AUTOUPDATER` and the `doctor.sh` hook if either went missing, and warns (without auto-editing) if the wrapper regressed to setting `LD_LIBRARY_PATH` via env. Silent when clean; runs only on interactive shell startup, never inside a Claude-spawned Bash-tool shell.
- **`doctor.sh` `SessionStart` hook**: runs the sanity check automatically at the start of every session (`install.sh` step 8). `autocheck.sh` only checks it for staleness at shell startup, not re-run there — that would be redundant with the session-start run.
- **Update recognition**: `doctor.sh` remembers the last two `claude --version` strings seen (`.last-claude-version`). If this session's binary differs from last session's — typically right after `termux-update-claude` — it reports `UPDATED: ... (was: ...)`. A neutral signal, not a warning, but wired through the same `SessionStart` hook so claude sees it and mentions the version change unprompted (per the `CLAUDE.md` pointer) instead of only if you ask.
- **Locking**: self-heal and `update.sh`'s install step share one `flock`, so two Termux tabs open at once can't race and corrupt the binary.
- **Repatch-frequency escalation**: 2+ re-patches in 24h escalates from a quiet fix notice to an explicit warning that `DISABLE_AUTOUPDATER` isn't actually holding.
- **Update / rollback**: `termux-update-claude` downloads → verifies SHA-256 → patches → installs, swapping in the new binary only once every check passes, with automatic retry/resume on a dropped connection. `--rollback` restores the previous binary (kept as `claude.prev`; a rejected build is kept as `claude.rejected`, not deleted).
- **Version pinning**: `termux-update-claude --pin` locks onto a specific version, so neither a manual run nor `autocheck.sh`'s silent per-shell check ever advances past it — `--pin` alone pins whatever's currently installed (no download); `--pin <version>` downloads/verifies/installs that exact version first, same pipeline as a normal update, then pins it. `--unpin` resumes tracking `stable`. A drift between the pin and what's actually installed (e.g. after a manual `--rollback`) is surfaced, never silently auto-corrected — `autocheck.sh`'s self-heal is local-only (chmod/re-patch) and deliberately never downloads on its own, so `doctor.sh` and the check-only nudge report the mismatch and leave the ~300MB fetch to an explicit `termux-update-claude` run. Whether Anthropic's CDN keeps old versions' manifests reachable indefinitely is unverified — an old pin can eventually 404; that failure is reported the same way any other update failure is, with a full log saved to `$DEST/update-fail-<timestamp>.log`.
- **`settings.json` backup**: `install.sh`, `autocheck.sh`, and `uninstall.sh` each back up `~/.claude/settings.json` to `settings.json.bak` before touching the `DISABLE_AUTOUPDATER` key or the `doctor.sh` hook. Restore with `cp ~/.claude/settings.json.bak ~/.claude/settings.json`; `doctor.sh` reports backup status.
- **Termux:API notifications** (optional — `pkg install termux-api` + the Termux:API app, not installed by `install.sh`): if `termux-notification` is available, a real update failure or a repatch-frequency escalation each push a notification, so they're not missed in a backgrounded tab. `doctor.sh` reports whether this is wired up.
- **`doctor.sh`**: one-shot diagnostic dump — arch/ABI cross-check (catches binary-translation layers), kernel `epoll_pwait2` risk (checked against whether the *installed binary* carries the upstream fix, not just the kernel version), paths, binary/interpreter state, leaked `LD_*` env, autoupdater-disabled check, `settings.json` backup status, Termux:API wiring, optional session-hooks wiring, optional ADB-bridge wiring + live connection state, Termux build freshness (flags a likely stale/Play-Store install), glibc/patchelf version drift, `$HOME` `noexec` check, free disk space, and `--version` (with update recognition). Run this first, before guessing.
- **Release tracking** ([`.github/workflows/track-claude-release.yml`](.github/workflows/track-claude-release.yml)): runs hourly (and on manual `workflow_dispatch`) on a GitHub-hosted `ubuntu-24.04-arm` runner — resolves the current `stable` version, and if this repo doesn't have a release for it yet, downloads the `linux-arm64` binary, verifies its SHA-256 against Anthropic's manifest, confirms `--version` runs on real arm64 glibc Linux (no patching needed for that), then publishes a GitHub Release tagged `claude-<version>`. This only confirms Anthropic's build itself is intact — it does **not** verify anything Bionic/Termux-specific (the patchelf interpreter swap, `epoll_pwait2`, ...), since a GitHub-hosted runner can't exercise that path. Deliberately schedule/`workflow_dispatch`-only, never `pull_request`-triggered — this repo is public, and self-hosted runners (which could give full-fidelity Bionic testing) were considered and set aside specifically because of that.
  - `doctor.sh --json` — the same checks as one JSON object (needs `jq`), for scripting.
  - `doctor.sh --fix` — runs the same locked self-heal block as `autocheck.sh`, then the normal dump, on demand instead of only at shell startup.
- **`termux-doctor` skill**: the trap list, self-repair design, and golden rules live in a Claude Code skill (`~/.claude/skills/termux-doctor/`) instead of every session's context via CLAUDE.md — claude invokes it on demand when it recognizes a symptom from this setup.
- **Staged reference docs** (always, not opt-in — [`docs/`](docs/), staged whole to `~/.claude/claude-native/docs/`): `architecture.md` (file-by-file map), `claude-code-hooks-reference.md` (general Claude Code hook behavior, verified the hard way), `termux-api-survey.md` (every `termux-*` command surveyed, built vs. deferred vs. rejected), `keybindings-notes.md` (the rationale behind `keybindings.json.template`'s rebinds). Kept OUT of `~/.claude/CLAUDE.md` on purpose — `CLAUDE.md.template` points at `docs/architecture.md` instead of describing internals itself, so `CLAUDE.md`'s footprint (loaded into every session, every project) stays roughly constant as this repo grows; the detail is opt-in-by-read, not paid for every session regardless of relevance. Adding a new file here needs no `install.sh` edit — it stages every `docs/*.md` generically.
- **Termux-friendly keybindings** (default, not opt-in — [`keybindings.json.template`](keybindings.json.template), `install.sh` step 11): Termux's default extra-keys row has no Shift key, and CTRL/ALT are only reachable as a tap-then-key (not held), so a few of Claude Code's default bindings don't work at all, or need an awkward two-tap `ctrl+x`-chord within a 1-second window. Merged into `~/.claude/keybindings.json` as single `alt+key` alternatives instead:
  - `alt+m` → `chat:cycleMode` (default `shift+tab` — unreachable, no Shift key)
  - `alt+b` → `app:toggleBrief` (default `ctrl+shift+b` — same problem)
  - `alt+left`/`alt+right`/`alt+up`/`alt+down`/`alt+home`/`alt+end` → `selection:extendLeft/Right/Up/Down/LineStart/LineEnd` (default `shift+arrow`/`shift+home`/`shift+end` — same problem; lets you select terminal text to copy without a Shift key)
  - `ctrl+x ctrl+s` → `chat:stash`, replacing the default plain `ctrl+s` (which risks being read as terminal XOFF flow control, freezing output until `ctrl+q`)
  - `alt+x` → `chat:killAgents`, `alt+g` → `task:background`, `alt+a` → `abovePrompt:toggle`, `alt+d` → `app:cycleDiffBase` (Diff­Panel) — single-tap alternatives to each action's `ctrl+x`-prefixed chord
  - All additive (your own bindings and the originals still work) and merged by value rather than by marker comment (JSON has no comment syntax): `install.sh` remembers exactly which entries it added in `~/.claude/claude-native/.keybindings-managed.json`, so re-running it after a template change replaces just those entries — anything else in your `keybindings.json` is left alone. `uninstall.sh` reverses it the same way. Don't hand-edit a value *inside* one of these managed entries (add your own separate binding instead) — a later `install.sh` run won't recognize the edit as ours and may re-add the original alongside it.
- **Toggling opt-in features after install** (`termux-claude-features`, `scripts/claude-features.sh`): `install.sh --with-notifications`/`--with-adb-bridge` are for the *first* install only. To turn either one on or off afterward — without re-running `install.sh` (which only adds) or `uninstall.sh` (which removes the whole setup) — use:
  - `termux-claude-features status` — what's on/off, plus live ADB connection state.
  - `termux-claude-features enable <notifications|adb-bridge>` / `disable <notifications|adb-bridge>`.
  - The actual wiring logic (`scripts/feature-hooks.sh`) is shared code: `install.sh --with-X`, `uninstall.sh`, and `termux-claude-features` all call the exact same `enable_X`/`disable_X` functions, so none of the three can drift out of sync with each other.
- **Session hooks** (opt-in — enable/disable with `termux-claude-features {enable|disable} notifications`, `scripts/session-hooks.sh`): wires three Claude Code hooks to Termux:API so the phone tells you things without you watching the terminal.
  - `UserPromptSubmit` → `termux-wake-lock`, `Stop` → `termux-wake-unlock`: holds a wake lock only while Claude is actually working on a turn, so Android doesn't throttle/kill a long-running task in the background when the screen locks. Needs only bare Termux — no Termux:API app required. Ref-counted across concurrent Termux tabs/sessions via a shared lockfile + per-session marker files, so one tab finishing its turn can't drop the wake lock out from under a different tab still mid-task.
  - `Notification` (matcher: `permission_prompt|idle_prompt|agent_needs_input|agent_completed`) → a `termux-notification`, so a permission prompt or an idle wait doesn't go unnoticed off-screen.
  - `Stop` also pushes a "task finished" notification, but only if the turn ran 60+ seconds — short back-and-forth chat stays quiet.
  - **Battery-aware context**: `UserPromptSubmit` also checks `termux-battery-status`, and if the device is at or below 20% and not charging, feeds Claude a plain-text heads-up as turn context (not a human-facing notification) — so Claude itself can choose to batch work or hold off on long unattended background tasks instead of draining a low battery, without you having to say so. Silent whenever battery is fine, charging, or the check can't complete (capped at 3s so a missing/ungranted Termux:API app never delays a turn).
  - All of the above need `pkg install termux-api` + the Termux:API app; `doctor.sh` reports whether they're wired and whether Termux:API is available. Every action is best-effort and never blocks a turn (hooks always exit 0 — there's no documented safe way to recover a blocked `Stop` hook, so this repo doesn't try).
- **ADB bridge** (opt-in — enable/disable with `termux-claude-features {enable|disable} adb-bridge`, `scripts/adb-bridge.sh`, [`adb-bridge` skill](skills/adb-bridge/SKILL.md)): lets Claude see and drive the *entire* Android screen, not just what's inside Termux, via a wireless ADB connection **paired from the device to itself** (no computer needed). Solves a real gap Termux's own tools can't: `termux-api` has no screenshot command, and Termux's own `screencap`/`logcat` are restricted to `root`/`system`/`shell` UIDs.
  - `status`/`screenshot`/`dump` (exact-coordinate `uiautomator` UI dump)/`tap`/`swipe`/`logcat`/`logcat-clear` subcommands on `adb-bridge.sh`.
  - **Security-sensitive**: `adb shell` runs at the `shell` UID (broad system visibility, input injection anywhere), and a pairing persists until revoked in Developer options — not just for one session. The skill's "Security posture" section covers this in full; short version: ask before a new pairing, never wire it into a background/per-turn hook, remind the user to disconnect when done.
  - The opt-in `Stop` hook nags (never blocks) if a device is still connected when a turn ends; `doctor.sh` also reports live connection state and whether the hook is wired.
- **Scheduled jobs** (`termux-claude-job`, always installed — not opt-in, since nothing runs until you explicitly schedule one): runs a headless `claude -p "<prompt>"` on a real Android JobScheduler schedule, not plain cron — a background loop/cron job gets killed by Android the moment the screen locks or Doze kicks in; JobScheduler actually wakes the device for it.
  - `termux-claude-job add <name> --prompt "..." [--prompt-file PATH] [--period-ms N] [--cwd DIR] [--persisted] [--charging] [--network TYPE]` — schedules it (omit `--period-ms` for one-shot; Android clamps periodic jobs to a 15-minute/900000ms minimum). Re-running `add` with the same name replaces its schedule (same underlying job-id, derived deterministically from the name).
  - `termux-claude-job list` / `log <name>` / `run <name>` (trigger once now, for testing) / `remove <name>`.
  - Each run reuses `session-hooks.sh`'s own ref-counted wake-lock (so a background job can't steal the lock out from under — or get its own stolen by — a concurrent interactive session) and its 60s+ "task finished" notification; a non-zero exit additionally pushes a distinct failure notification. Output is logged to `~/.claude/claude-native/jobs/<name>.log`.
  - `uninstall.sh` cancels each job by its specific job-id (never `--cancel-all`, which would also cancel any unrelated `termux-job-scheduler` job another tool on the device has scheduled — Android's JobScheduler has no per-app job namespacing within Termux).
- **`termux-open`/`termux-share`**: not wrapped by this repo — they're already plain shell commands once `termux-api` is installed — but documented in the `CLAUDE.md.template` section (see above) so Claude knows to use them directly: `termux-open <path>` opens a file/URL in its default Android app, `termux-share <path>` opens Android's share sheet for it. Lets Claude hand off a finished artifact (a report, an image, a generated file) straight into the rest of your phone's app ecosystem instead of just printing a path.

## Troubleshooting

Symptom → cause → fix, for the failure modes hit while building this.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Any Bionic command (`mkdir`, `ls`, and *especially* the bash Claude Code spawns for its own Bash tool) dies with `bad ELF magic: 2f2a2047` / `CANNOT LINK EXECUTABLE ... bash` | `LD_LIBRARY_PATH` was set via an environment variable (even `env LD_LIBRARY_PATH=... exec claude`) — it leaks into every child process, and Bionic's linker loads glibc's `libc.so` by mistake | Never set it via env. Invoke the linker with `--library-path` on the command line instead — that only applies to the one `exec`, never leaks. After fixing, fully quit and reopen Termux; a running session already inherited the bad env. |
| 2 | `Permission denied` / `cannot execute: Success` running the binary | Missing execute bit after download/patch (the "Success" line is just a stale errno being misprinted) | `chmod +x` |
| 3 | `grep`/`rg` dies mid-session with `invalid ELF header` | Bionic's `LD_PRELOAD` (preloaded by Termux by default) leaked into a glibc process | `unset LD_PRELOAD` in the wrapper; never put `env.LD_PRELOAD` in `settings.json` |
| 4 | `cannot execute` / interpreter not found, or it points at `/lib/ld-linux-aarch64.so.1` | Binary was never patched, or got overwritten by an unpatched build (usually the in-process autoupdater) | Re-run `patchelf --set-interpreter`, then `chmod +x` (this is exactly what `autocheck.sh` automates) |
| 5 | claude exits immediately with "native binary not installed" | You have Anthropic's newer binary-distribution mechanism, which has no Android target | You need a patched `linux-arm64` build specifically, not one from `npm`/`claude install` |
| 6 | Segfault right after `patchelf` | Some glibc binaries don't tolerate patching | Fallback: don't patch it, run via `grun <binary>` instead (it unsets `LD_PRELOAD` and sets the library path itself) |
| 7 | Write errors to `/tmp` / `EACCES` at runtime | Android has no `/tmp`, and `TMPDIR` isn't set/doesn't exist | Export a writable `TMPDIR` (e.g. `~/.cache/claude-tmp`) and `mkdir -p` it |
| 8 | Bare `grep` inside a Claude Code Bash-tool call fails with `-G: error while loading shared libraries: -G: cannot open shared object file` (real `command grep`/`rg` still work) | Claude Code injects a `grep` shell function that re-execs itself as a hidden ripgrep "ugrep" personality via `CLAUDE_CODE_EXECPATH`, which claude overwrites from `process.execPath` (`readlink /proc/self/exe`) right before that re-exec. If the wrapper explicitly `exec`'d `ld-linux --library-path ... claude`, the kernel records *ld-linux*, not `claude`, as the process's exe_file — so the overwritten path points at the linker, which then gets grep-style flags it can't parse. | Have the wrapper `exec` the patched binary directly, with no explicit `ld-linux` call — the kernel then records the binary itself as exe_file, so `process.execPath` resolves correctly. Works because Termux's `ld.so.cache` already covers the glibc lib dir, so no `--library-path` flag is needed. Fall back to `ld-linux --library-path` only if a preflight `--version` check shows direct-exec fails. As with trap #1, fully quit and reopen Termux for the fix to take effect. |
| 9 | `claude` segfaults immediately on launch, no useful error | **Not a seccomp block.** A TLS fault inside glibc's generic `syscall()` wrapper, triggered when Bun's kernel-version gate (5.11+) attempts `epoll_pwait2` through it — confirmed on an OPPO CPH2499, Android 16, kernel 5.15.180. The kernel is fixed at manufacture and doesn't change on an OS upgrade, so the Android version shown in Settings tells you nothing; only the real kernel does. | **Fixed upstream** in [oven-sh/bun#32490](https://github.com/oven-sh/bun/pull/32490): the syscall now goes via raw inline asm, the gate skips `epoll_pwait2` on `-android` kernels, and `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` force-disables it. `doctor.sh` checks whether the installed binary carries the fix rather than assuming every 5.11+ kernel is unpatched; the wrapper also sets that env var as a harmless belt-and-suspenders. On an old build that predates the fix, [gtbuchanan/claude-code-termux](https://github.com/gtbuchanan/claude-code-termux) ships a working LD_PRELOAD shim. The wrapper also warns about this risk *before* launch (reading a cache `update.sh`/`autocheck.sh` maintain, since `strings` on a ~300MB binary is too slow to redo every launch) — a `--version` preflight alone can't catch this, since it never touches the code path that crashes. |

## Manual verification

```sh
uname -m                                            # expect: aarch64
echo "$PREFIX"; echo "$HOME"
command -v claude; readlink -f "$(command -v claude)"
file ~/.claude/claude-native/claude
patchelf --print-interpreter ~/.claude/claude-native/claude
ls -l "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
env | grep -i '^LD_'
bash ~/.claude/claude-native/doctor.sh
```

## Updating

Claude Code's own autoupdater is disabled (`DISABLE_AUTOUPDATER=1`, see "Why this exists" above) — it would otherwise install a stock binary that can't run on Bionic. `termux-update-claude` replaces it: download → verify SHA-256 against Anthropic's manifest → patch → install, so `claude` never ends up on a broken binary mid-update.

```sh
termux-update-claude              # check for + apply an update
termux-update-claude --rollback   # revert to the previously installed binary
termux-update-claude --pin        # lock onto whatever's currently installed
termux-update-claude --pin 2.1.260  # download/install/pin that exact version
termux-update-claude --unpin      # resume tracking stable
```

A currently-running `claude` session can't hot-swap its own binary — quit and reopen after updating. The next session then recognizes the change on its own — see "Update recognition" above.

## Uninstall

```sh
cd ~/claude-code-termux-native   # wherever you cloned it
bash uninstall.sh          # keeps the downloaded binary cached
bash uninstall.sh --full   # also deletes the cached binary
```

Removes `claude` / `termux-update-claude` / `termux-claude-job` / `termux-claude-features`, the `~/.bashrc` hook, `DISABLE_AUTOUPDATER`, the `doctor.sh` hook, the optional session hooks and the optional ADB-bridge `Stop` hook + skill (removed unconditionally — safe no-op if either was never enabled), the self-repair scripts, the `termux-doctor` skill, and our section of `~/.claude/CLAUDE.md` (only what's between its markers). Keeps the ~300MB binary + `manifest.json` cached by default so a future install skips the download; `--full` wipes that too.

**Only want to turn off `notifications` or `adb-bridge`, not remove the whole install?** Use `termux-claude-features disable <feature>` instead — see [Extra features](#extra-features-beyond-a-bare-install). `uninstall.sh` is for removing this repo's setup entirely.

Leaves the Termux packages (`glibc`, `patchelf`, `jq`, `ripgrep`, ...) and the cloned repo directory alone either way — neither is exclusively this project's to remove; `uninstall.sh` prints the command if you want them gone too.

## Contributing

The issues and fixes above came from real breakage, not speculation. Hit a new one on a different Termux/glibc version? A PR adding it to the table (symptom → cause → fix) is exactly the contribution this repo wants.

New to the codebase? [`docs/architecture.md`](docs/architecture.md) is a file-by-file map of what every script does and how the opt-in-feature pattern (staged script → `feature-hooks.sh` → three thin callers: `install.sh`/`uninstall.sh`/`termux-claude-features`) fits together — read that before README's install-focused prose if you're here to change code rather than just use it.

## License

GPL-3.0 for the scripts — see [LICENSE](LICENSE). The `claude` binary is downloaded from, and remains the property of, Anthropic, under [its own terms](https://www.anthropic.com/legal).
