#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/3d-import-job-functions.sh"

legacy_queue="${ORGANIZE_3D_LEGACY_QUEUE:-$HOME/.hazel-organize-3d-imports-queue}"
lock="$THREE_D_SPOOL_ROOT/.worker-lock"
organizer="${ORGANIZE_3D_ORGANIZER:-$script_dir/../organization/organize-3d-imports.sh}"
worker_log="${ORGANIZE_3D_WORKER_LOG:-$HOME/Library/Logs/automation-scripts/hazel/hazel-organize-3d-imports-worker.log}"
typeset -i failed_count=0

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

process_pending_job() {
    local pending_job="$1"
    local job_id running_job staging_path organizer_status
    job_id="$(basename "$pending_job")"
    running_job="$THREE_D_RUNNING_DIR/$job_id"

    if ! command mv "$pending_job" "$running_job" 2>/dev/null; then
        return
    fi
    update_3d_job_state "$running_job" "running" "Worker claimed job"
    staging_path=$(command jq -r '.stagingPath' "$running_job/job.json")

    if [[ ! -d "$staging_path" ]]; then
        log_worker "ERROR job $job_id has no staging directory: $staging_path"
        update_3d_job_state "$running_job" "failed" "Staging directory is missing"
        move_3d_job "$running_job" "$THREE_D_FAILED_DIR"
        failed_count=$((failed_count + 1))
        return
    fi

    log_worker "Processing job $job_id: $staging_path"
    organizer_status=0
    ORGANIZE_3D_JOB_ID="$job_id" "$organizer" "$staging_path" || organizer_status=$?
    if (( organizer_status == 0 )); then
        update_3d_job_state "$running_job" "done" "Organizer completed successfully"
        move_3d_job "$running_job" "$THREE_D_DONE_DIR"
        cleanup_staging_container "$job_id" "$staging_path"
        log_worker "Completed job $job_id"
        return
    fi

    update_3d_job_state "$running_job" "failed" "Organizer exited with status $organizer_status"
    move_3d_job "$running_job" "$THREE_D_FAILED_DIR"
    failed_count=$((failed_count + 1))
    log_worker "ERROR job $job_id failed with exit $organizer_status"
}

migrate_legacy_queue

while :; do
    typeset -a pending_jobs
    pending_jobs=("$THREE_D_PENDING_DIR"/*(N/))
    (( ${#pending_jobs[@]} == 0 )) && break

    local_job=""
    for local_job in "${pending_jobs[@]}"; do
        process_pending_job "$local_job"
    done
done

cleanup_worker
trap - EXIT

typeset -a remaining_jobs
remaining_jobs=("$THREE_D_PENDING_DIR"/*(N/))
if (( ${#remaining_jobs[@]} > 0 )) && [[ "${ORGANIZE_3D_WORKER_ONCE:-0}" != "1" ]]; then
    nohup "$0" </dev/null >>"$worker_log" 2>&1 &!
fi

((failed_count == 0))
