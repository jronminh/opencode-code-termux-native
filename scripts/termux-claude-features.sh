#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/termux-claude-features by install.sh.
# Thin exec wrapper, same pattern as termux-update-claude.sh -> update.sh.
# See scripts/claude-features.sh.
exec "$HOME/.claude/claude-native/claude-features.sh" "$@"
