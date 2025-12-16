#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
orig_dir="$(cd "$(dirname "$src")" && pwd)"
queue="$HOME/.hazel-organize-video-imports-queue"
script_dir="$(cd "$(dirname "$0")" && pwd)"

inbox="/Volumes/Videos/Import/Organize/_temp"
mkdir -p "$inbox"

base="$(basename "$src")"
dest="$inbox/$base"

# Avoid collisions in inbox
if [[ -e "$dest" ]]; then
	ts="$(date +%s)"
	ext="${base##*.}"
	name_no_ext="${base%.*}"
	if [[ "$ext" == "$base" ]]; then
		dest="$inbox/${name_no_ext}_$ts"
	else
		dest="$inbox/${name_no_ext}_$ts.$ext"
	fi
fi

cp -p "$src" "$dest"

# Enqueue copied file path along with original directory context
print -- "$dest\t$orig_dir" >> "$queue"

# Kick worker in background
"$script_dir/hazel-organize-video-imports-worker.sh" & disown

exit 0
