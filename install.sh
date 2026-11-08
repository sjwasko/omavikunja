#!/usr/bin/env bash
# Copy this checkout into the Omarchy plugin folder (the shell's plugin scan
# does not follow symlinks). The shell hot-reloads on save.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.config/omarchy/plugins/sjwasko.omavikunja"
mkdir -p "$dest"
rsync -a --delete --exclude .git --exclude node_modules --exclude install.sh "$src/" "$dest/"
echo "Installed to $dest"
