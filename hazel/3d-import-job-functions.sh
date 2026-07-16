#!/usr/bin/env zsh

if [[ -n "${THREE_D_IMPORT_JOBS_LOADED:-}" ]]; then
    return 0
fi
THREE_D_IMPORT_JOBS_LOADED=1

THREE_D_BASE_PATH="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
THREE_D_SPOOL_ROOT="${ORGANIZE_3D_SPOOL_ROOT:-$HOME/Library/Application Support/automation-scripts/3d-import-jobs}"
THREE_D_STAGING_ROOT="${ORGANIZE_3D_STAGING_ROOT:-$THREE_D_BASE_PATH/_temp}"
THREE_D_PENDING_DIR="$THREE_D_SPOOL_ROOT/pending"
THREE_D_RUNNING_DIR="$THREE_D_SPOOL_ROOT/running"
THREE_D_FAILED_DIR="$THREE_D_SPOOL_ROOT/failed"
THREE_D_QUARANTINE_DIR="$THREE_D_SPOOL_ROOT/quarantine"
THREE_D_DONE_DIR="$THREE_D_SPOOL_ROOT/done"
THREE_D_STATUS_FILE="$THREE_D_SPOOL_ROOT/status.json"

initialize_3d_job_directories() {
    command mkdir -p \
        "$THREE_D_STAGING_ROOT" \
        "$THREE_D_PENDING_DIR" \
        "$THREE_D_RUNNING_DIR" \
        "$THREE_D_FAILED_DIR" \
        "$THREE_D_QUARANTINE_DIR" \
        "$THREE_D_DONE_DIR"
}

generate_3d_job_id() {
    local timestamp candidate
    timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
    while :; do
        candidate="${timestamp}-$$-${RANDOM}"
        if [[ ! -e "$THREE_D_PENDING_DIR/$candidate" &&
            ! -e "$THREE_D_RUNNING_DIR/$candidate" &&
            ! -e "$THREE_D_FAILED_DIR/$candidate" &&
            ! -e "$THREE_D_QUARANTINE_DIR/$candidate" &&
            ! -e "$THREE_D_DONE_DIR/$candidate" &&
            ! -e "$THREE_D_STAGING_ROOT/$candidate" ]]; then
            print -r -- "$candidate"
            return
        fi
    done
}

write_3d_job_manifest() {
    local manifest_path="$1"
    local job_id="$2"
    local source_name="$3"
    local staging_path="$4"
    local legacy="${5:-0}"
    local timestamp max_attempts
    timestamp=$(date -Iseconds)
    max_attempts="${ORGANIZE_3D_MAX_ATTEMPTS:-3}"

    command jq -n \
        --arg id "$job_id" \
        --arg source "$source_name" \
        --arg staging "$staging_path" \
        --arg timestamp "$timestamp" \
        --arg legacy "$legacy" \
        --arg max_attempts "$max_attempts" \
        '{
            schemaVersion: "1.0",
            id: $id,
            state: "pending",
            sourceName: $source,
            stagingPath: $staging,
            createdAt: $timestamp,
            updatedAt: $timestamp,
            attempts: 0,
            maxAttempts: ($max_attempts | tonumber),
            nextAttemptAt: null,
            nextAttemptEpoch: 0,
            activeWorkerPid: null,
            lastExitCode: null,
            lastError: null,
            importedFromLegacyQueue: ($legacy == "1"),
            history: [{
                state: "pending",
                at: $timestamp,
                message: "Job accepted"
            }]
        }' >"$manifest_path"
}

publish_3d_job() {
    local job_id="$1"
    local source_name="$2"
    local staging_path="$3"
    local legacy="${4:-0}"
    local job_tmp="$THREE_D_PENDING_DIR/.${job_id}.tmp.$$"
    local job_final="$THREE_D_PENDING_DIR/$job_id"

    command mkdir "$job_tmp"
    if ! write_3d_job_manifest "$job_tmp/job.json" "$job_id" "$source_name" "$staging_path" "$legacy"; then
        command rm -rf "$job_tmp"
        return 1
    fi
    if ! command mv "$job_tmp" "$job_final"; then
        command rm -rf "$job_tmp"
        return 1
    fi
    if ! write_3d_spool_status "Job $job_id accepted"; then
        print -u2 -r -- "WARNING: Job $job_id was accepted, but spool status could not be refreshed"
    fi
    return 0
}

enqueue_3d_import() {
    local source_path="$1"
    [[ -d "$source_path" ]] || {
        print -u2 -r -- "Input must be an existing directory: $source_path"
        return 1
    }

    initialize_3d_job_directories

    local job_id source_name stage_tmp stage_final
    job_id=$(generate_3d_job_id)
    source_name="$(basename "$source_path")"
    stage_tmp="$THREE_D_STAGING_ROOT/.${job_id}.tmp.$$"
    stage_final="$THREE_D_STAGING_ROOT/$job_id"

    command mkdir "$stage_tmp"
    if ! command cp -R "$source_path" "$stage_tmp/payload"; then
        command rm -rf "$stage_tmp"
        return 1
    fi
    command mv "$stage_tmp" "$stage_final"

    if ! publish_3d_job "$job_id" "$source_name" "$stage_final/payload"; then
        command rm -rf "$stage_final"
        return 1
    fi

    print -r -- "$job_id"
}

enqueue_legacy_3d_import() {
    local staging_path="$1"
    [[ -d "$staging_path" ]] || return 1

    initialize_3d_job_directories

    local job_id source_name stage_tmp stage_final
    job_id=$(generate_3d_job_id)
    source_name="$(basename "$staging_path")"
    stage_tmp="$THREE_D_STAGING_ROOT/.${job_id}.tmp.$$"
    stage_final="$THREE_D_STAGING_ROOT/$job_id"

    command mkdir "$stage_tmp"
    if ! command mv "$staging_path" "$stage_tmp/payload"; then
        command rmdir "$stage_tmp" 2>/dev/null || true
        return 1
    fi
    command mv "$stage_tmp" "$stage_final"

    if ! publish_3d_job "$job_id" "$source_name" "$stage_final/payload" 1; then
        command mv "$stage_final/payload" "$staging_path" 2>/dev/null || true
        command rm -rf "$stage_final"
        return 1
    fi

    print -r -- "$job_id"
}

update_3d_job_state() {
    local job_dir="$1"
    local new_state="$2"
    local message="$3"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp
    timestamp=$(date -Iseconds)

    command jq \
        --arg state "$new_state" \
        --arg message "$message" \
        --arg timestamp "$timestamp" \
        '.state = $state |
         .updatedAt = $timestamp |
         .history += [{
             state: $state,
             at: $timestamp,
             message: $message
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

claim_3d_job() {
    local job_dir="$1"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp epoch
    timestamp=$(date -Iseconds)
    epoch=$(date +%s)

    command jq \
        --arg timestamp "$timestamp" \
        --arg epoch "$epoch" \
        --arg pid "$$" \
        '.state = "running" |
         .updatedAt = $timestamp |
         .attempts = ((.attempts // 0) + 1) |
         .activeWorkerPid = ($pid | tonumber) |
         .claimedAt = $timestamp |
         .claimedAtEpoch = ($epoch | tonumber) |
         .nextAttemptAt = null |
         .nextAttemptEpoch = 0 |
         .history += [{
             state: "running",
             at: $timestamp,
             message: "Worker claimed job"
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

mark_3d_job_failed() {
    local job_dir="$1"
    local exit_code="$2"
    local message="$3"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp
    timestamp=$(date -Iseconds)

    command jq \
        --arg timestamp "$timestamp" \
        --arg exit_code "$exit_code" \
        --arg message "$message" \
        '.state = "failed" |
         .updatedAt = $timestamp |
         .activeWorkerPid = null |
         .lastExitCode = ($exit_code | tonumber) |
         .lastError = $message |
         .history += [{
             state: "failed",
             at: $timestamp,
             message: $message
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

schedule_3d_job_retry() {
    local job_dir="$1"
    local delay_seconds="$2"
    local message="$3"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp next_epoch next_timestamp
    timestamp=$(date -Iseconds)
    next_epoch=$(($(date +%s) + delay_seconds))
    next_timestamp=$(/bin/date -r "$next_epoch" +"%Y-%m-%dT%H:%M:%S%z")

    command jq \
        --arg timestamp "$timestamp" \
        --arg next_timestamp "$next_timestamp" \
        --arg next_epoch "$next_epoch" \
        --arg message "$message" \
        '.state = "pending" |
         .updatedAt = $timestamp |
         .nextAttemptAt = $next_timestamp |
         .nextAttemptEpoch = ($next_epoch | tonumber) |
         .history += [{
             state: "pending",
             at: $timestamp,
             message: $message
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

quarantine_3d_job() {
    local job_dir="$1"
    local message="$2"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp
    timestamp=$(date -Iseconds)

    command jq \
        --arg timestamp "$timestamp" \
        --arg message "$message" \
        '.state = "quarantined" |
         .updatedAt = $timestamp |
         .activeWorkerPid = null |
         .nextAttemptAt = null |
         .nextAttemptEpoch = 0 |
         .history += [{
             state: "quarantined",
             at: $timestamp,
             message: $message
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

complete_3d_job() {
    local job_dir="$1"
    local message="$2"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"
    local timestamp
    timestamp=$(date -Iseconds)

    command jq \
        --arg timestamp "$timestamp" \
        --arg message "$message" \
        '.state = "done" |
         .updatedAt = $timestamp |
         .activeWorkerPid = null |
         .nextAttemptAt = null |
         .nextAttemptEpoch = 0 |
         .lastExitCode = 0 |
         .lastError = null |
         .history += [{
             state: "done",
             at: $timestamp,
             message: $message
         }]' \
        "$manifest" >"$tmp"
    command mv "$tmp" "$manifest"
}

ensure_3d_job_attempt_count() {
    local job_dir="$1"
    local minimum_attempts="${2:-1}"
    local manifest="$job_dir/job.json"
    local tmp="$manifest.tmp.$$"

    if ! command jq \
        --arg minimum_attempts "$minimum_attempts" \
        '.attempts = ([.attempts // 0, ($minimum_attempts | tonumber)] | max)' \
        "$manifest" >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    command mv "$tmp" "$manifest"
}

write_3d_spool_status() {
    local message="${1:-Status refreshed}"
    local tmp="$THREE_D_STATUS_FILE.tmp.$$"
    local timestamp
    timestamp=$(date -Iseconds)

    local -a pending running failed quarantine done
    pending=("$THREE_D_PENDING_DIR"/*(N/))
    running=("$THREE_D_RUNNING_DIR"/*(N/))
    failed=("$THREE_D_FAILED_DIR"/*(N/))
    quarantine=("$THREE_D_QUARANTINE_DIR"/*(N/))
    done=("$THREE_D_DONE_DIR"/*(N/))

    if ! command jq -n \
        --arg timestamp "$timestamp" \
        --arg message "$message" \
        --arg pending "${#pending[@]}" \
        --arg running "${#running[@]}" \
        --arg failed "${#failed[@]}" \
        --arg quarantine "${#quarantine[@]}" \
        --arg done "${#done[@]}" \
        '{
            schemaVersion: "1.0",
            updatedAt: $timestamp,
            message: $message,
            counts: {
                pending: ($pending | tonumber),
                running: ($running | tonumber),
                failed: ($failed | tonumber),
                quarantined: ($quarantine | tonumber),
                done: ($done | tonumber)
            }
        }' >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    if ! command mv "$tmp" "$THREE_D_STATUS_FILE"; then
        command rm -f "$tmp"
        return 1
    fi
}

move_3d_job() {
    local job_dir="$1"
    local destination_dir="$2"
    command mv "$job_dir" "$destination_dir/$(basename "$job_dir")"
}
