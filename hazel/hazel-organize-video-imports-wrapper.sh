#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
queue="$HOME/.hazel-organize-video-imports-queue"
script_dir="$(cd "$(dirname "$0")" && pwd)"
log="$HOME/Library/Logs/hazel-organize-video-imports-wrapper.log"

mkdir -p "$(dirname "$log")"
umask 077

print -- "[$(date)] whoami=$(whoami) home=${HOME:-unset} shell=${SHELL:-unset} pwd=$(pwd)" >> "$log"

inbox="$(dirname "$src")"
base="$(basename "$src")"

# Log the invocation for debugging
print -- "[$(date)] src='$src' base='$base' inbox='$inbox' queue='$queue'" >> "$log"

# Ensure queue file exists and is writable, log failure if any
if ! touch "$queue" 2>>"$log"; then
	print -- "[$(date)] ERROR: unable to touch queue $queue" >> "$log"
	exit 1
fi
if ! print -- "$src\t$inbox" >> "$queue" 2>>"$log"; then
	print -- "[$(date)] ERROR: failed to append to queue $queue" >> "$log"
	exit 1
fi

# Show queue after append (last few lines)
tail -n 5 "$queue" >> "$log" 2>/dev/null || true

# Kick worker in background
print -- "[$(date)] Starting worker script $script_dir/hazel-organize-video-imports-worker.sh" >> "$log"
"$script_dir/hazel-organize-video-imports-worker.sh" & disown

print -- "[$(date)] Done" >> "$log"
exit 0
