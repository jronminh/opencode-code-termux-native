#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/claude by install.sh.
# Every line here works around a specific Bionic/glibc conflict — see
# README.md ("Troubleshooting") before changing anything.
unset LD_PRELOAD
export TMPDIR="$HOME/.cache/claude-tmp"
mkdir -p "$TMPDIR"
export USE_BUILTIN_RIPGREP=0
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_EXECPATH="$HOME/.claude/claude-native/claude"
# Belt-and-suspenders for trap #9 (oven-sh/bun#32489): forces the same safe
# epoll_pwait path the upstream fix (bun#32490) already takes by default on
# Bun builds that include it, and protects any older bundled Bun that
# predates it. Harmless either way.
export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1

BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

# Genuinely can't work at all — say so plainly instead of letting exec fail
# with a cryptic "No such file or directory".
if [ ! -e "$BIN" ]; then
  echo "claude binary missing at $BIN — run: ~/.claude/claude-native/update.sh" >&2
  exit 1
fi
if [ ! -e "$LD" ]; then
  echo "glibc loader missing at $LD (glibc-runner may have changed its path) — run doctor.sh" >&2
  exit 1
fi

# trap #9: the binary can pass every check below and still segfault once
# its event loop actually starts, because none of them exercise the
# epoll_pwait2 path that crashes on kernel 5.11+ with a pre-fix Bun build.
# A `strings` scan of a ~300MB binary is too slow to redo on every launch,
# so this reads a cache autocheck.sh/update.sh computed once — see README
# "Troubleshooting" #9. Not fatal (the env var above already forces the
# safe path on builds that check for it) — just a heads-up before the fact
# instead of a bare segfault with zero context after it.
EPOLL_CACHE="$HOME/.claude/claude-native/.epoll-fix-cache"
if [ -e "$EPOLL_CACHE" ] && [ "$(cat "$EPOLL_CACHE" 2>/dev/null)" = "0" ]; then
  KVER=$(uname -r); KMAJOR=${KVER%%.*}; KREST=${KVER#*.}; KMINOR=${KREST%%.*}
  if { [ "$KMAJOR" -gt 5 ] 2>/dev/null || { [ "$KMAJOR" -eq 5 ] 2>/dev/null && [ "$KMINOR" -ge 11 ] 2>/dev/null; }; }; then
    echo "warning: kernel $KVER + this claude build predate the epoll_pwait2 fix — may segfault once running even though it launches (README \"Troubleshooting\" #9). Run doctor.sh, or: termux-update-claude" >&2
  fi
fi

# Prefer exec'ing the patched binary directly (no explicit ld-linux
# invocation): the kernel then records the binary itself, not ld-linux, as
# the process's exe_file. That matters because Claude reads process.execPath
# (Node/Bun readlink /proc/self/exe under the hood) and overwrites
# CLAUDE_CODE_EXECPATH with it before re-exec'ing embedded tools like grep —
# see trap #8 in CLAUDE.md.template. Going through ld-linux made that
# overwritten value point at ld-linux itself, breaking every grep/find call
# inside the Bash tool regardless of restarts. This only works if the glibc
# runtime is already registered in ld.so.cache (confirmed true here); on an
# install where it isn't, fall back to the explicit --library-path form.
if "$BIN" --version >/dev/null 2>&1; then
  exec "$BIN" "$@"
fi

# Direct exec failed — most commonly trap #4 (interpreter drifted, usually
# an unpatched build overwriting ours). Try the same one-shot repatch
# autocheck.sh does at shell-open before falling back: cheap next to
# running a whole session in the degraded fallback mode below, and covers
# a binary that just changed moments ago in this same shell. Same lockfile
# as autocheck.sh/update.sh so this never races their writes to $BIN.
#
# Wait longer than autocheck.sh's own "flock -w 5" (scripts/autocheck.sh):
# autocheck.sh runs at every new shell's startup and can be mid-repatch of
# this exact binary when a *different*, already-open Termux tab launches
# claude at the same moment — a real scenario with Termux's tabbed UI, not
# just this same shell (which can't race itself: autocheck.sh finishes
# before the prompt it was sourced from even appears). Waiting less than
# autocheck.sh's own window meant losing that race by design and dropping
# into the degraded fallback below for the rest of the session, even
# though the binary was fine microseconds later. If the lock is genuinely
# stuck past that, skip to the fallback rather than block launch forever.
(
  flock -w 6 202 || exit 1
  patchelf --set-interpreter "$LD" "$BIN" 2>/dev/null && chmod +x "$BIN" 2>/dev/null
) 202>"$HOME/.claude/claude-native/.claude-native.lock"
if "$BIN" --version >/dev/null 2>&1; then
  exec "$BIN" "$@"
fi

# Still broken after a repatch attempt: fall back so claude at least
# launches, but say so first. This path is known to break grep/find inside
# Claude Code's own Bash tool (trap #8) — launching this way is a
# knowingly-degraded session, not a real fix.
echo "warning: claude isn't launching cleanly even after a repatch attempt — falling back to an explicit loader invocation. grep/find inside Claude Code's Bash tool may break (README \"Troubleshooting\" #8). Run doctor.sh for the real fix." >&2
exec "$LD" --library-path "$PREFIX/glibc/lib" "$BIN" "$@"
