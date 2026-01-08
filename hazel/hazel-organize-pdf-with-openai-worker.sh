#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-pdf-with-openai-queue"
lock="$HOME/.hazel-organize-pdf-with-openai-queue.lock"
log="$HOME/Library/Logs/hazel-organize-pdf-with-openai-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-pdf-with-openai.sh"

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    if [[ -f "$lock/pid" ]]; then
        stale_pid=$(<"$lock/pid")
        if ! kill -0 "$stale_pid" 2>/dev/null; then
            rmdir "$lock" 2>/dev/null || true
            mkdir "$lock" 2>/dev/null || exit 0
        else
            exit 0
        fi
    else
        rmdir "$lock" 2>/dev/null || true
        mkdir "$lock" 2>/dev/null || exit 0
    fi
fi
echo "$$" > "$lock/pid"
trap 'rm -f "$lock/pid" 2>/dev/null; rmdir "$lock" 2>/dev/null || true' EXIT

[[ -f "$queue" ]] || exit 0

while IFS= read -r pdf || [[ -n "${pdf-}" ]]; do
    [[ -z "$pdf" ]] && continue
    [[ ! -f "$pdf" ]] && continue

    {
        echo "[$(date)] Processing: $pdf"
        "$organizer" --move "$pdf"
        echo "[$(date)] Done: $pdf"
    } >>"$log" 2>&1 || echo "[$(date)] ERROR processing $pdf" >>"$log"
done < "$queue"

# Clear queue
: > "$queue"
