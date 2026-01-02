#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
inbox="$HOME/Documents/Guitar Tabs/_temp"
queue="$HOME/.hazel-organize-guitar-tabs-queue"
script_dir="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$inbox"

# Work on a copy so Hazel is free to move the original to Done
dest="$inbox/$(basename "$src")"
cp "$src" "$dest"

# Enqueue the copied file for processing
print -- "$dest" >> "$queue"

# Kick the worker in the background using local script
"$script_dir/hazel-organize-guitar-tabs-worker.sh" & disown

exit 0
