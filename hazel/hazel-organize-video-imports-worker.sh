#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-video-imports-queue"
lock="$HOME/.hazel-organize-video-imports-queue.lock"
log="$HOME/Library/Logs/hazel-organize-video-imports-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-video-imports.sh"

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    echo "[$(date)] Worker already running; exiting" >>"$log"
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

echo "[$(date)] Worker started" >>"$log"

[[ -f "$queue" ]] || exit 0

while IFS=$'\t' read -r video summaries_dir || [[ -n ${video-} ]]; do
    [[ -z "$video" ]] && { echo "[$(date)] Skipping blank line" >>"$log"; continue; }

    # Allow filesystem to settle after move before checking existence
    sleep 30

    if [[ ! -f "$video" ]]; then
        echo "[$(date)] Missing file after wait; skipping: $video" >>"$log"
        continue
    fi

    # Ensure permissions are sufficient for processing (common on remote shares)
    if ! chmod u+rwX "$video" 2>/dev/null; then
        echo "[$(date)] Warning: unable to adjust permissions (continuing): $video" >>"$log"
        if [[ ! -r "$video" ]]; then
            echo "[$(date)] Insufficient permissions; skipping: $video" >>"$log"
            continue
        fi
    fi

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
