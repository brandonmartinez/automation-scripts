#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
inbox="$HOME/Documents/3D Prints/_temp"
queue="$HOME/.hazel-organize-3d-imports-queue"
script_dir="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$inbox"

# Work on a copy so Hazel is free to move the original to Done
dest="$inbox/$(basename "$src")"
cp -R "$src" "$dest"

# Enqueue the copied file for processing
print -- "$dest" >> "$queue"

# Kick the worker in the background using local script
"$script_dir/hazel-organize-3d-imports-worker.sh" & disown

exit 0
