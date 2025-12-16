#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
queue="$HOME/.hazel-organize-video-imports-queue"
script_dir="$(cd "$(dirname "$0")" && pwd)"

inbox="/Volumes/Videos/Import/Organize/Done"
base="$(basename "$src")"
dest="$inbox/$base"

# Enqueue moved file path along with original directory context
print -- "$dest\t$inbox" >> "$queue"

# Kick worker in background
"$script_dir/hazel-organize-video-imports-worker.sh" & disown

exit 0
