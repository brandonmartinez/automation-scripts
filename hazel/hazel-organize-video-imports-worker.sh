#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-video-imports-queue"
queue_lock="$HOME/.hazel-organize-video-imports-queue.oplock"
lock="$HOME/.hazel-organize-video-imports-queue.lock"
log="$HOME/Library/Logs/hazel-organize-video-imports-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-video-imports.sh"

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
                echo "[$(date)] Removing stale queue lock (age ${age}s)" >>"$log"
                rmdir "$queue_lock" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.1
        waited=$(( waited + 1 ))
        if (( waited >= max_wait )); then
            echo "[$(date)] ERROR: queue lock wait exceeded" >>"$log"
            return 1
        fi
    done
}

release_queue_lock() {
    rmdir "$queue_lock" 2>/dev/null || true
}

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

while true; do
    if ! acquire_queue_lock; then
        echo "[$(date)] Failed to acquire queue lock; exiting" >>"$log"
        exit 1
    fi

    if [[ ! -s "$queue" ]]; then
        release_queue_lock
        break
    fi

    batch_file="${queue}.processing.$$"
    if mv "$queue" "$batch_file" 2>/dev/null; then
        : > "$queue"
    else
        echo "[$(date)] ERROR: unable to move queue to batch" >>"$log"
        release_queue_lock
        exit 1
    fi

    release_queue_lock

    while IFS= read -r video || [[ -n ${video-} ]]; do
        video="${video//$'\r'/}"
        [[ -z "$video" ]] && { echo "[$(date)] Skipping blank line" >>"$log"; continue; }

        {
            echo "[$(date)] Processing: $video"
            "$organizer" "$video"
            echo "[$(date)] Done: $video"
        } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $video" >>"$log"
    done < "$batch_file"

    rm -f "$batch_file"
done

echo "[$(date)] Worker finished" >>"$log"
