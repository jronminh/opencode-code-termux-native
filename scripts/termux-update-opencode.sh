#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/termux-update-opencode by install.sh.
# Manual "check for update / confirm update" command — running this IS the
# confirmation, no separate y/n prompt on top of it. See scripts/update.sh.
exec "$HOME/.opencode/opencode-native/update.sh" "$@"