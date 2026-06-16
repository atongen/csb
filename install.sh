#!/usr/bin/env bash
#
# install.sh — symlink csb's scripts into a bin directory on your PATH.
#
#   ./install.sh            # symlink into ~/bin
#   BIN_DIR=~/.local/bin ./install.sh

set -euo pipefail

src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd)
bin_dir="${BIN_DIR:-$HOME/bin}"

mkdir -p "$bin_dir"

for script in csb tm; do
  src="$src_dir/$script"
  dest="$bin_dir/$script"
  if [[ ! -f "$src" ]]; then
    echo "install: missing $src" >&2
    exit 1
  fi
  chmod +x "$src"
  ln -sfn "$src" "$dest"
  echo "install: $dest -> $src"
done

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "install: note — $bin_dir is not on your PATH" >&2 ;;
esac
