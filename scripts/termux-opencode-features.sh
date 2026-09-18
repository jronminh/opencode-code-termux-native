#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/termux-opencode-features by install.sh.
# Thin exec wrapper, same pattern as termux-update-opencode.sh -> update.sh.
# See scripts/opencode-features.sh.
exec "$HOME/.opencode/opencode-native/opencode-features.sh" "$@"