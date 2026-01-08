#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

queue="$HOME/.hazel-organize-pdf-with-openai-queue"
lock="$HOME/.hazel-organize-pdf-with-openai-queue.lock"
log="$HOME/Library/Logs/hazel-organize-pdf-with-openai-worker.log"
organizer="$HOME/src/automation-scripts/organization/organize-pdf-with-openai.sh"

ensure_openai_key() {
    # If already set, nothing to do
    [[ -n "${OPENAI_API_KEY:-}" ]] && return 0

    if ! command -v op >/dev/null 2>&1; then
        echo "[$(date)] ERROR: op CLI not found; cannot load OPENAI_API_KEY" >>"$log"
        return 1
    fi

    if ! OPENAI_API_KEY=$(op read "op://cli/openai-api/credential" 2>/dev/null); then
        echo "[$(date)] ERROR: Failed to read OPENAI_API_KEY from 1Password item cli/openai-api" >>"$log"
        return 1
    fi

    export OPENAI_API_KEY
}

ensure_openai_key || exit 1

# Only one worker at a time
if ! mkdir "$lock" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

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
