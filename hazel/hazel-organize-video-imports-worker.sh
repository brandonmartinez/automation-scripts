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
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

[[ -f "$queue" ]] || exit 0

while IFS=$'\t' read -r video original_dir || [[ -n ${video-} ]]; do
    [[ -z "$video" ]] && continue
    [[ ! -f "$video" ]] && continue

    if [[ -z "$original_dir" ]]; then
        original_dir="$(cd "$(dirname "$video")" && pwd)"
    fi

    summaries_dir="$original_dir"

    {
        echo "[$(date)] Processing: $video"
        "$organizer" --summaries-dir "$summaries_dir" "$video"
        echo "[$(date)] Done: $video"
    } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $video" >>"$log"
done < "$queue"

# Clear queue
: > "$queue"
