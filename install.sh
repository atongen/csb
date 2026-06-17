#!/usr/bin/env bash
#
# install.sh — copy csb into a bin directory on your PATH.
#
#   ./install.sh            # copy into ~/bin
#   BIN_DIR=~/.local/bin ./install.sh
#
# Copies (not symlinks): the target bin dir may itself be under version
# control, so it must hold real, portable file content.

set -euo pipefail

src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd)
bin_dir="${BIN_DIR:-$HOME/bin}"

mkdir -p "$bin_dir"

src="$src_dir/csb"
dest="$bin_dir/csb"
if [[ ! -f "$src" ]]; then
  echo "install: missing $src" >&2
  exit 1
fi
rm -f "$dest"          # clear any pre-existing symlink
cp "$src" "$dest"
chmod +x "$dest"
echo "install: copied -> $dest"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "install: note — $bin_dir is not on your PATH" >&2 ;;
esac
