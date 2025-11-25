#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-3d-imports-queue"
lock="$HOME/.hazel-organize-3d-imports-queue.lock"
log="$HOME/Library/Logs/hazel-organize-3d-imports-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-3d-imports.sh"

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

[[ -f "$queue" ]] || exit 0

while IFS= read -r entry || [[ -n "${entry-}" ]]; do
    [[ -z "$entry" ]] && continue
    [[ ! -d "$entry" ]] && continue

    {
        echo "[$(date)] Processing: $entry"
        "$organizer" "$entry"
        echo "[$(date)] Done: $entry"
    } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $entry" >>"$log"
done < "$queue"

# Clear queue
: > "$queue"
