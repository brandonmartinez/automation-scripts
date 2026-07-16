#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/3d-import-job-functions.sh"
worker_script_path="${0:A}"

legacy_queue="${ORGANIZE_3D_LEGACY_QUEUE:-$HOME/.hazel-organize-3d-imports-queue}"
lock="$THREE_D_SPOOL_ROOT/.worker-lock"
organizer="${ORGANIZE_3D_ORGANIZER:-$script_dir/../organization/organize-3d-imports.sh}"
worker_log="${ORGANIZE_3D_WORKER_LOG:-$HOME/Library/Logs/automation-scripts/hazel/hazel-organize-3d-imports-worker.log}"
retry_base_seconds="${ORGANIZE_3D_RETRY_BASE_SECONDS:-30}"
retry_max_seconds="${ORGANIZE_3D_RETRY_MAX_SECONDS:-900}"
typeset -i quarantined_count=0

initialize_3d_job_directories
command mkdir -p "$(dirname "$worker_log")"

# Only one worker at a time
acquire_worker_lock() {
    local stale_pid=""

    while :; do
        # Migrate stale directory locks from the previous worker implementation.
        if [[ -d "$lock" ]]; then
            [[ -f "$lock/pid" ]] && stale_pid=$(<"$lock/pid")
            if [[ "$stale_pid" == <-> ]] && kill -0 "$stale_pid" 2>/dev/null; then
                return 1
            fi
            command rm -f "$lock/pid" 2>/dev/null || true
            command rmdir "$lock" 2>/dev/null || return 1
            continue
        fi

        if (
            setopt noclobber
            print -r -- "$$" >"$lock"
        ) 2>/dev/null; then
            return 0
        fi

        if [[ -f "$lock" ]]; then
            stale_pid=$(<"$lock")
            if [[ "$stale_pid" == <-> ]] && kill -0 "$stale_pid" 2>/dev/null; then
                return 1
            fi
            command rm -f "$lock" 2>/dev/null || return 1
            continue
        fi
    done
}

acquire_worker_lock || exit 0

cleanup_worker() {
    if [[ -f "$lock" && "$(<"$lock")" == "$$" ]]; then
        command rm -f "$lock" 2>/dev/null || true
    fi
}
trap cleanup_worker EXIT

log_worker() {
    print -r -- "[$(date -Iseconds)] $*"
}

refresh_spool_status() {
    local message="$1"
    write_3d_spool_status "$message" || log_worker "WARNING spool status refresh failed"
}

notify_3d_import() {
    local title="$1"
    local message="$2"

    if [[ -n "${ORGANIZE_3D_NOTIFY_COMMAND:-}" ]]; then
        if ! "$ORGANIZE_3D_NOTIFY_COMMAND" "$title" "$message"; then
            log_worker "WARNING notification command failed: $title"
        fi
        return
    fi
    if [[ "${ORGANIZE_3D_DISABLE_NOTIFICATIONS:-0}" == "1" ]]; then
        return
    fi
    if command -v osascript >/dev/null 2>&1; then
        osascript - "$title" "$message" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
    fi
}

migrate_legacy_queue() {
    [[ -s "$legacy_queue" ]] || return 0

    local batch="${legacy_queue}.migrating.$$"
    if ! command mv "$legacy_queue" "$batch" 2>/dev/null; then
        return
    fi
    : >"$legacy_queue"

    local entry migrated_job_id
    while IFS= read -r entry || [[ -n "${entry-}" ]]; do
        [[ -z "$entry" ]] && continue
        if [[ ! -d "$entry" ]]; then
            log_worker "WARNING legacy queue entry is missing: $entry"
            continue
        fi
        if migrated_job_id=$(enqueue_legacy_3d_import "$entry"); then
            log_worker "Migrated legacy queue entry to job $migrated_job_id"
        else
            log_worker "ERROR failed to migrate legacy queue entry: $entry"
            print -r -- "$entry" >>"$legacy_queue"
        fi
    done <"$batch"

    command rm -f "$batch"
}

cleanup_staging_container() {
    local job_id="$1"
    local staging_path="$2"
    local container
    container="$(dirname "$staging_path")"
    if [[ "${container:A:h}" == "${THREE_D_STAGING_ROOT:A}" && "${container:t}" == "$job_id" ]]; then
        command rm -rf "$container"
    fi
    return 0
}

retry_delay_for_job() {
    local job_dir="$1"
    local attempts delay
    attempts=$(command jq -r '.attempts // 1' "$job_dir/job.json")
    delay=$((retry_base_seconds * (2 ** (attempts - 1))))
    (( delay > retry_max_seconds )) && delay=$retry_max_seconds
    print -r -- "$delay"
}

route_failed_job() {
    local failed_job="$1"
    local job_id attempts max_attempts delay source_name
    job_id="$(basename "$failed_job")"
    attempts=$(command jq -r '.attempts // 0' "$failed_job/job.json")
    max_attempts=$(command jq -r '.maxAttempts // 3' "$failed_job/job.json")
    source_name=$(command jq -r '.sourceName // .id' "$failed_job/job.json")
    if (( attempts < 1 )); then
        ensure_3d_job_attempt_count "$failed_job"
        attempts=1
    fi

    if (( attempts < max_attempts )); then
        delay=$(retry_delay_for_job "$failed_job")
        schedule_3d_job_retry "$failed_job" "$delay" "Retry scheduled in ${delay}s"
        move_3d_job "$failed_job" "$THREE_D_PENDING_DIR"
        log_worker "Retry scheduled for job $job_id in ${delay}s (attempt $attempts/$max_attempts)"
        refresh_spool_status "Job $job_id scheduled for retry"
        return
    fi

    quarantine_3d_job "$failed_job" "Maximum attempts exhausted"
    move_3d_job "$failed_job" "$THREE_D_QUARANTINE_DIR"
    quarantined_count=$((quarantined_count + 1))
    log_worker "QUARANTINED job $job_id after $attempts attempts"
    notify_3d_import "3D Import Needs Attention" "$source_name was quarantined after $attempts failed attempts."
    refresh_spool_status "Job $job_id quarantined"
}

recover_abandoned_jobs() {
    local -a running_jobs failed_jobs
    local job_dir job_id job_state source_name staging_path
    running_jobs=("$THREE_D_RUNNING_DIR"/*(N/))
    for job_dir in "${running_jobs[@]}"; do
        job_id="$(basename "$job_dir")"
        job_state=$(command jq -r '.state // "running"' "$job_dir/job.json")
        case "$job_state" in
            done)
                staging_path=$(command jq -r '.stagingPath' "$job_dir/job.json")
                move_3d_job "$job_dir" "$THREE_D_DONE_DIR"
                cleanup_staging_container "$job_id" "$staging_path"
                source_name=$(command jq -r '.sourceName // .id' "$THREE_D_DONE_DIR/$job_id/job.json")
                log_worker "Recovered completed job $job_id"
                notify_3d_import "3D Import Complete" "$source_name was organized successfully."
                ;;
            failed)
                log_worker "Recovering failed job $job_id without replacing its failure details"
                move_3d_job "$job_dir" "$THREE_D_FAILED_DIR"
                ;;
            quarantined)
                source_name=$(command jq -r '.sourceName // .id' "$job_dir/job.json")
                move_3d_job "$job_dir" "$THREE_D_QUARANTINE_DIR"
                quarantined_count=$((quarantined_count + 1))
                log_worker "Recovered quarantined job $job_id"
                notify_3d_import "3D Import Needs Attention" "$source_name remains quarantined after recovery."
                ;;
            pending)
                log_worker "Recovering pending job $job_id"
                move_3d_job "$job_dir" "$THREE_D_PENDING_DIR"
                ;;
            running)
                log_worker "Recovering abandoned running job $job_id"
                ensure_3d_job_attempt_count "$job_dir"
                mark_3d_job_failed "$job_dir" 75 "Recovered abandoned running job"
                move_3d_job "$job_dir" "$THREE_D_FAILED_DIR"
                ;;
            *)
                log_worker "ERROR job $job_id has invalid lifecycle state: $job_state"
                quarantine_3d_job "$job_dir" "Invalid lifecycle state recovered: $job_state"
                move_3d_job "$job_dir" "$THREE_D_QUARANTINE_DIR"
                quarantined_count=$((quarantined_count + 1))
                ;;
        esac
    done

    failed_jobs=("$THREE_D_FAILED_DIR"/*(N/))
    for job_dir in "${failed_jobs[@]}"; do
        route_failed_job "$job_dir"
    done
}

job_is_due() {
    local job_dir="$1"
    local next_epoch now
    next_epoch=$(command jq -r '.nextAttemptEpoch // 0' "$job_dir/job.json")
    now=$(date +%s)
    (( next_epoch <= now ))
}

process_pending_job() {
    local pending_job="$1"
    local job_id running_job staging_path organizer_status
    job_id="$(basename "$pending_job")"
    running_job="$THREE_D_RUNNING_DIR/$job_id"

    if ! command mv "$pending_job" "$running_job" 2>/dev/null; then
        return
    fi
    claim_3d_job "$running_job"
    refresh_spool_status "Worker claimed job $job_id"
    staging_path=$(command jq -r '.stagingPath' "$running_job/job.json")

    if [[ ! -d "$staging_path" ]]; then
        log_worker "ERROR job $job_id has no staging directory: $staging_path"
        mark_3d_job_failed "$running_job" 66 "Staging directory is missing"
        move_3d_job "$running_job" "$THREE_D_FAILED_DIR"
        route_failed_job "$THREE_D_FAILED_DIR/$job_id"
        return
    fi

    log_worker "Processing job $job_id: $staging_path"
    organizer_status=0
    ORGANIZE_3D_JOB_ID="$job_id" "$organizer" "$staging_path" || organizer_status=$?
    if (( organizer_status == 0 )); then
        complete_3d_job "$running_job" "Organizer completed successfully"
        move_3d_job "$running_job" "$THREE_D_DONE_DIR"
        cleanup_staging_container "$job_id" "$staging_path"
        log_worker "Completed job $job_id"
        local source_name
        source_name=$(command jq -r '.sourceName // .id' "$THREE_D_DONE_DIR/$job_id/job.json")
        notify_3d_import "3D Import Complete" "$source_name was organized successfully."
        refresh_spool_status "Job $job_id completed"
        return
    fi

    mark_3d_job_failed "$running_job" "$organizer_status" "Organizer exited with status $organizer_status"
    move_3d_job "$running_job" "$THREE_D_FAILED_DIR"
    log_worker "ERROR job $job_id failed with exit $organizer_status"
    route_failed_job "$THREE_D_FAILED_DIR/$job_id"
}

migrate_legacy_queue
recover_abandoned_jobs

while :; do
    typeset -a pending_jobs
    typeset -i processed_count=0
    pending_jobs=("$THREE_D_PENDING_DIR"/*(N/))
    (( ${#pending_jobs[@]} == 0 )) && break

    local_job=""
    for local_job in "${pending_jobs[@]}"; do
        job_is_due "$local_job" || continue
        process_pending_job "$local_job"
        processed_count=$((processed_count + 1))
    done
    (( processed_count == 0 )) && break
done

refresh_spool_status "Worker cycle complete"
cleanup_worker
trap - EXIT

schedule_retry_worker() {
    local -a remaining_jobs
    local earliest now delay job next_epoch
    remaining_jobs=("$THREE_D_PENDING_DIR"/*(N/))
    (( ${#remaining_jobs[@]} == 0 )) && return

    earliest=0
    for job in "${remaining_jobs[@]}"; do
        next_epoch=$(command jq -r '.nextAttemptEpoch // 0' "$job/job.json")
        if (( earliest == 0 || next_epoch < earliest )); then
            earliest=$next_epoch
        fi
    done

    now=$(date +%s)
    delay=$((earliest - now))
    (( delay < 0 )) && delay=0
    nohup zsh -c 'command sleep "$1"; exec "$2"' _ "$delay" "$worker_script_path" \
        </dev/null >>"$worker_log" 2>&1 &!
}

typeset -a remaining_jobs
remaining_jobs=("$THREE_D_PENDING_DIR"/*(N/))
if (( ${#remaining_jobs[@]} > 0 )) && [[ "${ORGANIZE_3D_WORKER_ONCE:-0}" != "1" ]]; then
    schedule_retry_worker
fi

((quarantined_count == 0))
