#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-video-imports-queue"
lock="$HOME/.hazel-organize-video-imports-queue.lock"
log="$HOME/Library/Logs/hazel-organize-video-imports-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-video-imports.sh"
settle_timeout="${QUEUE_SETTLE_TIMEOUT:-5}"
settle_interval=1

# Clear stale lock (e.g., after kill -9)
if [[ -d "$lock" ]]; then
    # Seconds since last modification
    last_mod=$(stat -f %m "$lock" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - last_mod ))
    if (( age > 3600 )); then
        echo "[$(date)] Removing stale lock (age ${age}s)" >>"$log"
        rm -rf "$lock" 2>/dev/null || true
    else
        echo "[$(date)] Worker already running; exiting (lock age ${age}s)" >>"$log"
        exit 0
    fi
fi

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    echo "[$(date)] Worker already running; exiting" >>"$log"
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

echo "[$(date)] Worker started" >>"$log"

if [[ ! -f "$queue" ]]; then
    echo "[$(date)] No queue file; exiting" >>"$log"
    exit 0
fi

# Let the queue file settle in case it's still being appended to
if [[ -f "$queue" && $settle_timeout -gt 0 ]]; then
    last_mtime=$(stat -f %m "$queue" 2>/dev/null || echo 0)
    waited=0
    while (( waited < settle_timeout )); do
        sleep "$settle_interval"
        mtime=$(stat -f %m "$queue" 2>/dev/null || echo 0)
        if (( mtime == last_mtime )); then
            break
        fi
        last_mtime=$mtime
        waited=$(( waited + settle_interval ))
    done
fi

while IFS=$'\t' read -r video summaries_dir || [[ -n ${video-} ]]; do
    [[ -z "$video" ]] && { echo "[$(date)] Skipping blank line" >>"$log"; continue; }

    if [[ -z "$summaries_dir" ]]; then
        summaries_dir="$(cd "$(dirname "$video")" && pwd)"
    fi

    {
        echo "[$(date)] Processing: $video"
        "$organizer" --summaries-dir "$summaries_dir" "$video"
        echo "[$(date)] Done: $video"
    } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $video" >>"$log"
done < "$queue"

# Clear queue
: > "$queue"

echo "[$(date)] Worker finished" >>"$log"
