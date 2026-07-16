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
THREE_D_DONE_DIR="$THREE_D_SPOOL_ROOT/done"

initialize_3d_job_directories() {
    command mkdir -p \
        "$THREE_D_STAGING_ROOT" \
        "$THREE_D_PENDING_DIR" \
        "$THREE_D_RUNNING_DIR" \
        "$THREE_D_FAILED_DIR" \
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
    local timestamp
    timestamp=$(date -Iseconds)

    command jq -n \
        --arg id "$job_id" \
        --arg source "$source_name" \
        --arg staging "$staging_path" \
        --arg timestamp "$timestamp" \
        --arg legacy "$legacy" \
        '{
            schemaVersion: "1.0",
            id: $id,
            state: "pending",
            sourceName: $source,
            stagingPath: $staging,
            createdAt: $timestamp,
            updatedAt: $timestamp,
            attempts: 0,
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
    command mv "$job_tmp" "$job_final"
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

move_3d_job() {
    local job_dir="$1"
    local destination_dir="$2"
    command mv "$job_dir" "$destination_dir/$(basename "$job_dir")"
}
