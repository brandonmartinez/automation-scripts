#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-guitar-tabs-queue"
lock="$HOME/.hazel-organize-guitar-tabs-queue.lock"
log="$HOME/Library/Logs/hazel-organize-guitar-tabs-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-guitar-tabs.sh"

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

[[ -f "$queue" ]] || exit 0

while IFS= read -r tab || [[ -n "${tab-}" ]]; do
    [[ -z "$tab" ]] && continue
    [[ ! -f "$tab" ]] && continue

    {
        echo "[$(date)] Processing: $tab"
        "$organizer" "$tab"
        echo "[$(date)] Done: $tab"
    } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $tab" >>"$log"
done < "$queue"

# Clear queue
: > "$queue"
