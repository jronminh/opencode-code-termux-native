---
name: adb-bridge
description: Gives opencode direct sight of, and control over, the ENTIRE Android screen (not just Termux) through termux-adb-bridge's shell-UID daemon (`dsh`) — screenshots, exact-coordinate UI dumps, tap/swipe input injection, and full-system logcat. Use when termux-api/Termux's own tools can't see enough to debug or drive something (a permission dialog, an app-install prompt, an OEM-specific settings screen, any UI state or system log Termux's own restricted view can't reach). Opt-in and security-sensitive (commands run at the `shell` UID) — read "Security posture" before running anything here.
---

<!-- Installed and kept in sync by opencode-code-termux-native's install.sh
     (only with --with-adb-bridge, or via `termux-opencode-features enable
     adb-bridge`) from skills/adb-bridge/SKILL.md in that repo. A future
     install.sh run overwrites this file whole — don't hand-edit it; fix
     the repo copy instead, then re-run install.sh. -->

# adb-bridge

## Security posture — read this before doing anything else

`dsh` runs every command at the `shell` UID through termux-adb-bridge's
daemon — broad system visibility (full logcat, on-screen content via
screencap, synthetic tap/swipe/type anywhere, including other apps), not
scoped to Termux. That daemon persists until it is stopped or its pairing
is revoked; it is not a one-shot grant.

- **This is a deliberate, opt-in capability, not a default.** The bridge
  itself was installed and paired once by the user (`~/termux-adb-bridge`);
  enabling this skill only exposes it to opencode. Don't enable it, or
  extend its use, without the user's say-so.
- **Never wire screenshot/dump/tap/logcat into a background process or a
  scheduled termux-opencode-job run.** Every use must be a deliberate,
  visible action tied to a specific need in the conversation (e.g. "let me
  look at what's on screen to see why that install failed"). This
  capability must never act silently.
- **When finished, remember the shell-UID daemon is still running.** If the
  user is done with it, stop the daemon (see `~/termux-adb-bridge/README.md`)
  and/or `termux-opencode-features disable adb-bridge` to remove this skill.
  `adb-bridge.sh status` / `doctor.sh` report live reachability. (Unlike the
  claude repo there is no Stop hook here — opencode has no hook system — so
  hygiene is your job, every turn you finish with it.)
- A `tap`/`swipe` is a real action on the live device, same trust level as
  a shell command. Driving through a multi-step debug flow autonomously is
  fine; leave the final tap of anything truly consequential (confirming an
  app install, a payment, a destructive dialog) for the human to do by
  hand.

## Prerequisites (no pairing here — termux-adb-bridge did that)

There is no `adb`/android-tools step: everything goes through `dsh`, the
wrapper over the already-running termux-adb-bridge daemon.

1. `termux-adb-bridge` is installed and its daemon is running — the
   one-time Wireless-Debugging pairing happened during its setup. See
   `~/termux-adb-bridge/README.md`.
2. Confirm: `~/.opencode/opencode-native/adb-bridge.sh status` (or
   `dsh --check`) should print `shell UID reachable`. If not, start the
   daemon with `~/termux-adb-bridge/maintain/deploy.sh`.

`dsh` lives at `$PREFIX/bin/dsh` (override the script's binary with
`DSH_BIN=`).

## Commands (`~/.opencode/opencode-native/adb-bridge.sh`)

| Command | What it does |
| :--- | :--- |
| `status [--json]` | daemon reachable? which device? — always check this first |
| `screenshot [PATH]` | screencap, written locally, prints the path — `Read` it directly (opencode is multimodal) |
| `dump [PATH]` | `uiautomator dump`, written locally — XML with exact `bounds="[x1,y1][x2,y2]"` per element |
| `tap X Y` | `input tap` at exact coordinates |
| `swipe X1 Y1 X2 Y2 [MS]` | `input swipe` |
| `logcat [LINES]` | last LINES of the full system log (default 500), one-shot |
| `logcat-clear` | clear the log buffer — do this before reproducing an issue, then `logcat` to see only the new entries |
| `nag` | shell-UID reminder — informational only here (no hook calls it) |

## Workflow that actually works

- **Don't compute tap coordinates from a screenshot's displayed/scaled
  size.** A screenshot is often shown scaled down from the real
  resolution (e.g. 923×2000 displayed vs 1080×2340 real — a ~1.17×
  factor); a small arithmetic slip lands the tap outside the intended
  element. This exact mistake once dismissed a bottom-sheet dialog by
  tapping ~600px off target. Prefer: `dump` → read the `bounds=` for the
  target element → compute its center → `tap` there. Use a screenshot for
  the broad "what's on screen" picture, `dump` for the precise coordinate.
- **If an action doesn't produce the expected UI change, check `logcat`
  before taking another screenshot.** In the incident that motivated this
  skill, the screen alone looked like "nothing happened" after a tap, but
  `logcat` revealed the real cause immediately (an app crash with a full
  stack trace) — something no screenshot could show.
- Termux's own `logcat`/`screencap` are restricted to `root`/`system`/
  `shell` UIDs and fail silently or with a generic error from Termux's own
  (unprivileged app-UID) shell — this is precisely the gap `dsh` closes,
  since the bridge daemon runs as `shell`.

## Further reading

`notes/termux-features-research.md` section "4b" has the full incident
write-up this skill was extracted from (a real Termux:Widget install
failure debugged live via this exact toolchain), including the actual
root cause it uncovered and the reasoning behind the security-posture
rules above.
