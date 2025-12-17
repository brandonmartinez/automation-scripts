#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

src="$1"
queue="$HOME/.hazel-organize-video-imports-queue"
queue_lock="$HOME/.hazel-organize-video-imports-queue.oplock"
script_dir="$(cd "$(dirname "$0")" && pwd)"
log="$HOME/Library/Logs/hazel-organize-video-imports-wrapper.log"

mkdir -p "$(dirname "$log")"
umask 077

print -- "[$(date)] whoami=$(whoami) home=${HOME:-unset} shell=${SHELL:-unset} pwd=$(pwd)" >> "$log"

inbox="$(dirname "$src")"
base="$(basename "$src")"

# Log the invocation for debugging
print -- "[$(date)] src='$src' base='$base' inbox='$inbox' queue='$queue'" >> "$log"

acquire_queue_lock() {
    local waited=0
    local max_wait=50 # 5s total (50 * 0.1s)
    while true; do
        if mkdir "$queue_lock" 2>/dev/null; then
            break
        fi

        if [[ -d "$queue_lock" ]]; then
            last_mod=$(stat -f %m "$queue_lock" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$(( now - last_mod ))
            if (( age > 3600 )); then
                print -- "[$(date)] Removing stale queue lock (age ${age}s)" >> "$log"
                rmdir "$queue_lock" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.1
        waited=$(( waited + 1 ))
        if (( waited >= max_wait )); then
            print -- "[$(date)] ERROR: queue lock wait exceeded" >> "$log"
            return 1
        fi
    done
}

release_queue_lock() {
    rmdir "$queue_lock" 2>/dev/null || true
}

# Ensure queue file exists and append atomically under lock
if ! acquire_queue_lock; then
    exit 1
fi
trap release_queue_lock EXIT

if ! touch "$queue" 2>>"$log" || ! print -- "$src" >> "$queue" 2>>"$log"; then
    print -- "[$(date)] ERROR: failed to append to queue $queue" >> "$log"
    exit 1
fi

release_queue_lock
trap - EXIT

# Show queue after append (last few lines)
tail -n 5 "$queue" >> "$log" 2>/dev/null || true

# Kick worker fully detached (no TTY/stdio ties)
print -- "[$(date)] Starting worker script $script_dir/hazel-organize-video-imports-worker.sh (nohup, detached)" >> "$log"
if ! nohup "$script_dir/hazel-organize-video-imports-worker.sh" </dev/null >>"$log" 2>&1 &!; then
    print -- "[$(date)] ERROR: failed to launch worker" >> "$log"
fi

print -- "[$(date)] Done" >> "$log"
exit 0
