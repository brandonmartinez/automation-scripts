#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
ARCHIVE_ROOT="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
CATALOG_DB_OVERRIDE=""
CATALOG_HTML_OVERRIDE=""
CATALOG_HEALTH_OVERRIDE=""
COMMAND="rebuild"
APPLY_FINDER_TAGS=0

usage() {
    cat <<'USAGE'
Usage: manage-3d-print-catalog.sh [rebuild|backfill|render|health] [options]

Commands:
  rebuild    Recreate the generated catalog, then scan, render, and report (default)
  backfill   Read the archive and upsert projects without changing project contents
  render     Regenerate the static HTML browser from the current catalog
  health     Regenerate the catalog health report

Options:
  --archive <path>      3D print archive root
  --db <path>           SQLite catalog path
  --html <path>         Static HTML catalog path
  --health-file <path>  Health report path
  --finder-tags         Apply canonical category/subcategory Finder tags
  -h, --help            Show this help
USAGE
}

if [[ $# -gt 0 && "$1" != -* ]]; then
    COMMAND="$1"
    shift
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)
            [[ $# -ge 2 ]] || { print -u2 -- "--archive requires a path"; exit 2; }
            ARCHIVE_ROOT="$2"
            shift 2
            ;;
        --db)
            [[ $# -ge 2 ]] || { print -u2 -- "--db requires a path"; exit 2; }
            CATALOG_DB_OVERRIDE="$2"
            shift 2
            ;;
        --html)
            [[ $# -ge 2 ]] || { print -u2 -- "--html requires a path"; exit 2; }
            CATALOG_HTML_OVERRIDE="$2"
            shift 2
            ;;
        --health-file)
            [[ $# -ge 2 ]] || { print -u2 -- "--health-file requires a path"; exit 2; }
            CATALOG_HEALTH_OVERRIDE="$2"
            shift 2
            ;;
        --finder-tags)
            APPLY_FINDER_TAGS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -- "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

case "$COMMAND" in
    rebuild|backfill|render|health) ;;
    *)
        print -u2 -- "Unknown command: $COMMAND"
        usage
        exit 2
        ;;
esac

[[ -d "$ARCHIVE_ROOT" ]] || { print -u2 -- "Archive root does not exist: $ARCHIVE_ROOT"; exit 1; }
ARCHIVE_ROOT="$(cd "$ARCHIVE_ROOT" &>/dev/null && pwd)"
export ORGANIZE_3D_BASE_PATH="$ARCHIVE_ROOT"
[[ -n "$CATALOG_DB_OVERRIDE" ]] && export ORGANIZE_3D_CATALOG_DB="$CATALOG_DB_OVERRIDE"
[[ -n "$CATALOG_HTML_OVERRIDE" ]] && export ORGANIZE_3D_CATALOG_HTML="$CATALOG_HTML_OVERRIDE"
[[ -n "$CATALOG_HEALTH_OVERRIDE" ]] && export ORGANIZE_3D_CATALOG_HEALTH="$CATALOG_HEALTH_OVERRIDE"
export ORGANIZE_3D_APPLY_FINDER_TAGS="$APPLY_FINDER_TAGS"

source "$SCRIPT_DIR/../utilities/logging.sh"
setup_script_logging "manage-3d-print-catalog"
source "$SCRIPT_DIR/3d-print-catalog-functions.sh"
ORGANIZE_3D_LIBRARY_ONLY=1 source "$SCRIPT_DIR/organize-3d-imports.sh"

for required_command in jq sqlite3 shasum find sort stat base64; do
    command -v "$required_command" >/dev/null 2>&1 || {
        log_error "Missing required command: $required_command"
        exit 1
    }
done

create_synthetic_catalog_state() {
    local project_path="$1"
    local output_file="$2"
    local project_relative="${project_path#$ARCHIVE_ROOT/}"
    local category="${project_relative%%/*}"
    local remainder="${project_relative#*/}"
    local subcategory="${remainder%%/*}"
    local project_name="${project_path:t}"
    local generated_at
    generated_at=$(date -Iseconds)

    local entries_file discovered_files
    entries_file=$(command mktemp -t 3d-backfill-files.XXXXXX.jsonl)
    discovered_files=$(command mktemp -t 3d-backfill-discovery.XXXXXX)
    if ! command find "$project_path" -type f -print0 | LC_ALL=C command sort -z >"$discovered_files"; then
        command rm -f "$entries_file" "$discovered_files"
        return 1
    fi
    local file relative filename extension size_bytes sha256 file_category source_url base skip pattern
    while IFS= read -r -d '' file; do
        base="${file:t}"
        skip=0
        for pattern in "${IGNORE_PATTERNS[@]}"; do
            if [[ "$base" == $~pattern ]]; then
                skip=1
                break
            fi
        done
        (( skip )) && continue

        relative="${file#$project_path/}"
        filename="$base"
        extension=""
        [[ "$filename" == *.* ]] && extension="${filename##*.}"
        extension="${extension:l}"
        if ! size_bytes=$(command stat -f%z "$file" 2>/dev/null ||
            command stat -c%s "$file" 2>/dev/null); then
            command rm -f "$entries_file" "$discovered_files"
            return 1
        fi
        if ! sha256=$(command shasum -a 256 "$file" | command awk '{print $1}'); then
            command rm -f "$entries_file" "$discovered_files"
            return 1
        fi
        file_category=$(classify_extension "$extension")
        source_url=""
        if [[ "$extension" == "webloc" ]]; then
            source_url=$(extract_webloc_url "$file" || true)
        fi
        if ! command jq -cn \
            --arg relative "$relative" \
            --arg filename "$filename" \
            --arg extension "$extension" \
            --arg size "$size_bytes" \
            --arg sha256 "$sha256" \
            --arg category "$file_category" \
            --arg source_url "$source_url" \
            '{
                relativePath: $relative,
                filename: $filename,
                extension: $extension,
                sizeBytes: ($size | tonumber),
                sha256: $sha256,
                category: $category,
                sourceUrl: (if $source_url == "" then null else $source_url end)
            }' >>"$entries_file"; then
            command rm -f "$entries_file" "$discovered_files"
            return 1
        fi
    done <"$discovered_files"
    command rm -f "$discovered_files"

    local files_json
    if ! files_json=$(command jq -s 'to_entries | map(.value + {id: .key})' "$entries_file"); then
        command rm -f "$entries_file"
        return 1
    fi
    command rm -f "$entries_file"
    command jq -n \
        --arg generated "$generated_at" \
        --arg folder "$project_name" \
        --arg destination "$project_relative" \
        --arg category "$category" \
        --arg subcategory "$subcategory" \
        --argjson files "$files_json" \
        '{
            metadata: {
                schemaVersion: "catalog-backfill-1.0",
                generatedAt: $generated,
                folderName: $folder,
                totalFiles: ($files | length),
                archivePlan: {
                    category: $category,
                    subcategory: $subcategory,
                    folderName: $folder,
                    destinationPath: $destination
                }
            },
            files: $files
        }' >"$output_file"
}

catalog_state_matches_synthetic_inventory() {
    local state_file="$1"
    local synthetic_state="$2"
    command jq -e --slurpfile synthetic "$synthetic_state" '
        def inventory:
            [
                .files[] |
                {
                    path: (.appliedPath // .relativePath),
                    sizeBytes,
                    sha256
                }
            ] | sort_by(.path);
        inventory == ($synthetic[0] | inventory)
    ' "$state_file" >/dev/null 2>&1
}

backfill_catalog() {
    initialize_3d_catalog || return 1
    local discovered_projects
    discovered_projects=$(command mktemp -t 3d-backfill-projects.XXXXXX)
    if ! command find "$ARCHIVE_ROOT" -mindepth 3 -maxdepth 3 -type d \
        ! -path "$ARCHIVE_ROOT/_*" ! -path '*/_*' -print0 |
        LC_ALL=C command sort -z >"$discovered_projects"; then
        command rm -f "$discovered_projects"
        return 1
    fi
    local project state_file state_for_index metadata_status synthetic_state category subcategory
    local indexed=0
    local failed=0
    local total_projects=0
    while IFS= read -r -d '' project; do
        total_projects=$((total_projects + 1))
        state_file="$project/$DEFAULT_STATE_FILENAME"
        state_for_index="$state_file"
        metadata_status="valid"
        synthetic_state=$(command mktemp -t 3d-backfill-state.XXXXXX.json)
        if ! create_synthetic_catalog_state "$project" "$synthetic_state"; then
            log_warn "Could not inventory project for catalog backfill: $project"
            command rm -f "$synthetic_state"
            failed=$((failed + 1))
            continue
        fi

        if [[ ! -f "$state_file" ]]; then
            metadata_status="missing-state"
        elif ! command jq -e '(.metadata | type) == "object" and (.files | type) == "array"' \
            "$state_file" >/dev/null 2>&1; then
            metadata_status="invalid-state"
        elif ! validate_3d_catalog_state "$state_file"; then
            metadata_status="incomplete-state"
        elif ! catalog_state_matches_synthetic_inventory "$state_file" "$synthetic_state"; then
            metadata_status="incomplete-state"
        fi

        if [[ "$metadata_status" != "valid" ]]; then
            state_for_index="$synthetic_state"
        fi

        if index_3d_project_from_state "$state_for_index" "$project" "$metadata_status"; then
            indexed=$((indexed + 1))
            category="${project#$ARCHIVE_ROOT/}"
            category="${category%%/*}"
            local project_remainder="${project#$ARCHIVE_ROOT/$category/}"
            subcategory="${project_remainder%%/*}"
            apply_3d_project_finder_tags "$project" "$category" "$subcategory" ||
                log_warn "Finder tags failed for $project"
        else
            log_warn "Catalog indexing failed for $project"
            failed=$((failed + 1))
        fi
        command rm -f "$synthetic_state"
    done <"$discovered_projects"
    command rm -f "$discovered_projects"
    log_info "Cataloged $indexed of $total_projects project directories"
    (( failed == 0 ))
}

replace_catalog_from_archive() {
    local mode="$1"
    local final_db="$THREE_D_CATALOG_DB"
    local staged_db="$final_db.staged.$$"
    command mkdir -p "$(dirname "$final_db")" || return 1
    command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"

    if [[ "$mode" == "backfill" && -f "$final_db" ]]; then
        if ! command sqlite3 -batch "$final_db" ".backup $(catalog_sql_quote "$staged_db")"; then
            command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"
            return 1
        fi
    fi

    THREE_D_CATALOG_DB="$staged_db"
    if ! backfill_catalog; then
        THREE_D_CATALOG_DB="$final_db"
        command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"
        return 1
    fi
    if ! command sqlite3 -batch "$staged_db" \
        'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;' >/dev/null; then
        THREE_D_CATALOG_DB="$final_db"
        command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"
        return 1
    fi
    command rm -f "$staged_db-wal" "$staged_db-shm"

    THREE_D_CATALOG_DB="$final_db"
    if [[ -f "$final_db" ]] &&
        ! command sqlite3 -batch "$final_db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null; then
        command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"
        return 1
    fi
    command rm -f "$final_db-wal" "$final_db-shm"
    if ! command mv "$staged_db" "$final_db"; then
        command rm -f "$staged_db" "$staged_db-wal" "$staged_db-shm"
        return 1
    fi
}

if [[ "$COMMAND" == "rebuild" ]]; then
    log_info "Rebuilding generated 3D print catalog"
    replace_catalog_from_archive "rebuild"
    render_3d_catalog_html
    write_3d_catalog_health_report
elif [[ "$COMMAND" == "backfill" ]]; then
    log_info "Backfilling 3D print catalog without changing project contents"
    replace_catalog_from_archive "backfill"
    render_3d_catalog_html
    write_3d_catalog_health_report
elif [[ "$COMMAND" == "render" ]]; then
    render_3d_catalog_html
elif [[ "$COMMAND" == "health" ]]; then
    write_3d_catalog_health_report
fi

log_info "Catalog database: $THREE_D_CATALOG_DB"
[[ "$COMMAND" != "health" ]] && log_info "Catalog browser: $THREE_D_CATALOG_HTML"
[[ "$COMMAND" != "render" ]] && log_info "Health report: $THREE_D_CATALOG_HEALTH"
