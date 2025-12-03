#!/usr/bin/env zsh

# Set Shell Options
set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# ============================================================================
# CONSTANTS AND CONFIGURATION
# ============================================================================

# Validate required environment
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# Configuration constants
readonly PAPERWORK_DIR="${PAPERWORK_DIR:-$HOME/Documents/Paperwork}"

record_final_plan_outcome() {
    update_state_file '
        .plan.final = {
            sender: (if $sender == "" then null else $sender end),
            department: (if $department == "" then null else $department end),
            category: (if $category == "" then null else $category end),
            sentOn: (if $sent_on == "" then null else $sent_on end),
            additionalContext: (if $additional == "" then null else $additional end),
            organizerDescription: (if $organizer == "" then null else $organizer end),
            fileNameDescription: (if $file_desc == "" then null else $file_desc end),
            summary: (if $summary == "" then null else $summary end)
        }
    ' --arg sender "$SENDER" --arg department "$DEPARTMENT" --arg category "$CATEGORY" --arg sent_on "$SENT_ON" --arg additional "$ADDITIONAL_CONTEXT" --arg organizer "$ORGANIZER_DESCRIPTION" --arg file_desc "$FILE_NAME_DESCRIPTION" --arg summary "$SHORT_SUMMARY"
}

record_action_snapshot() {
    local proposed="$1"
    local applied="$2"
    local finder_comment="$3"
    update_state_file '
        .action.proposedPath = (if $proposed == "" then null else $proposed end) |
        .action.appliedPath = (if $applied == "" then null else $applied end) |
        .action.finderComment = (if $comment == "" then null else $comment end) |
        .action.completed = ($applied != "")
    ' --arg proposed "$proposed" --arg applied "$applied" --arg comment "$finder_comment"
}
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-DEBUG}"
readonly MAX_PDF_TEXT_LENGTH=100000
readonly OCR_SCRIPT="$SCRIPT_DIR/../media/pdf-ocr-text.sh"
readonly DEFAULT_STATE_FILENAME="agentic-plan.json"
readonly AGENTIC_SCHEMA_VERSION="pdf-agentic-v1"
_structure_cache_ttl="${PAPERWORK_STRUCTURE_CACHE_TTL:-900}"
if [[ ! "$_structure_cache_ttl" == <-> ]]; then
    _structure_cache_ttl=900
fi
readonly STRUCTURE_CACHE_TTL="$_structure_cache_ttl"
unset _structure_cache_ttl
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/organize-pdf-with-openai"
readonly AGENTIC_TEXT_SAMPLE_LIMIT=8000

# Global variables for processed data
declare -g PDF_FILE=""
declare -g SCANNED_AT=""
declare -g PDF_TEXT=""
declare -g FOLDER_STRUCTURE=""
declare -g AI_RESPONSE=""
declare -g MOVE_FILE=false
declare -g ADDITIONAL_CONTEXT=""
declare -g ORGANIZER_DESCRIPTION=""
declare -g FILE_NAME_DESCRIPTION=""
declare -g DRY_RUN=0
declare -g STATE_FILE=""
declare -g WORK_STATE_FILE=""
declare -g FILE_CREATED_AT=""
declare -g PRIMARY_DATE_SOURCE=""
declare -g PRIMARY_DATE_REASON=""

# ============================================================================
# INITIALIZATION AND VALIDATION
# ============================================================================

validate_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 [--move] [--dry-run] [--state-file <path>] <pdf_file_path>" >&2
        echo "Please provide a PDF file path to organize" >&2
        echo "Options:" >&2
        echo "  --move    Move the file instead of copying it" >&2
        echo "  --dry-run Analyze and plan without copying/moving files" >&2
        echo "  --state-file Persist the agentic JSON plan to a custom path" >&2
        exit 1
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
        --move)
            MOVE_FILE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --state-file)
            if [[ $# -lt 2 ]]; then
                echo "Error: --state-file requires a path" >&2
                exit 1
            fi
            STATE_FILE="$2"
            shift 2
            ;;
        --help | -h)
            echo "Usage: $0 [--move] [--dry-run] [--state-file <path>] <pdf_file_path>" >&2
            echo "Organizes PDF files using AI categorization" >&2
            echo "" >&2
            echo "Options:" >&2
            echo "  --move    Move the file instead of copying it" >&2
            echo "  --dry-run Analyze and plan without copying/moving files" >&2
            echo "  --state-file Persist the agentic JSON plan to a custom path" >&2
            echo "  --help    Show this help message" >&2
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            if [[ -z "$PDF_FILE" ]]; then
                PDF_FILE="$1"
            else
                echo "Error: Multiple PDF files specified. Only one file can be processed at a time." >&2
                exit 1
            fi
            shift
            ;;
        esac
    done

    if [[ -z "$PDF_FILE" ]]; then
        echo "Error: No PDF file specified" >&2
        echo "Use --help for usage information" >&2
        exit 1
    fi

    if [[ ! -f "$PDF_FILE" ]]; then
        echo "Error: '$PDF_FILE' does not exist or is not a file" >&2
        exit 1
    fi

    local pdf_dir pdf_base
    pdf_dir="$(cd "$(dirname "$PDF_FILE")" &>/dev/null && pwd)"
    pdf_base="$(basename "$PDF_FILE")"
    PDF_FILE="$pdf_dir/$pdf_base"
}

setup_environment() {
    # Ensure paperwork directory exists for logging
    if [[ ! -d "$PAPERWORK_DIR" ]]; then
        mkdir -p "$PAPERWORK_DIR"
    fi
    mkdir -p "$CACHE_DIR"

    # Initialize logging utility
    export LOG_LEVEL=0
    export LOG_FD=2
    source "$SCRIPT_DIR/../utilities/logging.sh"
    setup_script_logging
    set_log_level "$LOG_LEVEL_NAME"

    log_info "Sourcing Open AI Helpers from $SCRIPT_DIR"
    if [[ ! -f "$SCRIPT_DIR/../ai/open-ai-functions.sh" ]]; then
        log_error "OpenAI functions not found at $SCRIPT_DIR/../ai/open-ai-functions.sh"
        exit 1
    fi
    source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

    # Log header to mark new session start
    log_header "organize-pdf-with-openai.sh"

    initialize_state_document
}

# ============================================================================
# STATE MANAGEMENT HELPERS
# ============================================================================

initialize_state_document() {
    local generated_at file_size extension move_mode phases_json
    generated_at=$(date -Iseconds)
    file_size=$(stat -f%z "$PDF_FILE" 2>/dev/null || stat -c%s "$PDF_FILE" 2>/dev/null || echo 0)
    extension="${PDF_FILE##*.}"
    if [[ "$extension" == "$PDF_FILE" ]]; then
        extension=""
    fi
    move_mode="copy"
    if [[ "$MOVE_FILE" == true ]]; then
        move_mode="move"
    fi

    WORK_STATE_FILE=$(mktemp -t pdf-agentic.XXXXXX.json)
    phases_json=$(jq -n '["discovery","analysis","action"] | map({name: ., startedAt: null, completedAt: null, notes: []})')

    jq -n \
        --arg schema "$AGENTIC_SCHEMA_VERSION" \
        --arg generated "$generated_at" \
        --arg pdf "$PDF_FILE" \
        --arg filename "$(basename "$PDF_FILE")" \
        --arg dry "$DRY_RUN" \
        --arg mode "$move_mode" \
        --arg size "$file_size" \
        --arg ext "$extension" \
        --argjson phases "$phases_json" \
        '{
            metadata: {
                schemaVersion: $schema,
                generatedAt: $generated,
                dryRun: ($dry == "1"),
                moveMode: $mode,
                phases: $phases
            },
            file: {
                originalPath: $pdf,
                filename: $filename,
                extension: (if ($ext | length) == 0 then null else ($ext | ascii_downcase) end),
                sizeBytes: ($size|tonumber),
                createdAt: null
            },
            context: {
                scannedTimestamp: null,
                createdTimestamp: null,
                filenameDates: [],
                folderStructure: { categories: [] },
                textSample: "",
                textCharacters: 0,
                sentOn: null,
                additionalContext: null,
                organizerDescription: null,
                fileNameDescription: null
            },
            plan: {
                analysis: null,
                categorization: null,
                destination: null,
                final: null,
                rawResponse: null,
                confidence: null,
                rationale: []
            },
            action: {
                intendedOperation: $mode,
                dryRun: ($dry == "1"),
                proposedPath: null,
                appliedPath: null,
                finderComment: null,
                completed: false
            }
        }' >"$WORK_STATE_FILE"
}

update_state_file() {
    local tmp
    tmp=$(mktemp -t pdf-agentic-state.XXXXXX.json)
    jq "$@" "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

record_phase_start() {
    local phase="$1"
    local timestamp=$(date -Iseconds)
    update_state_file '
        .metadata.phases = (
            (if (.metadata.phases | type) == "array" then .metadata.phases else [] end)
            | if ((map(select(.name == $phase)) | length) == 0) then
                . + [{name: $phase, startedAt: $ts, completedAt: null, notes: []}]
              else
                map(if .name == $phase then . + {startedAt: $ts} else . end)
              end
        )
    ' --arg phase "$phase" --arg ts "$timestamp"
}

record_phase_complete() {
    local phase="$1"
    local timestamp=$(date -Iseconds)
    update_state_file '
        .metadata.phases = (
            (if (.metadata.phases | type) == "array" then .metadata.phases else [] end)
            | map(if .name == $phase then . + {completedAt: $ts} else . end)
        )
    ' --arg phase "$phase" --arg ts "$timestamp"
}

record_phase_note() {
    local phase="$1"
    local message="$2"
    local timestamp=$(date -Iseconds)
    update_state_file '
        .metadata.phases = (
            (if (.metadata.phases | type) == "array" then .metadata.phases else [] end)
            | map(
                if .name == $phase then
                    .notes = ((.notes // []) + [{timestamp: $ts, message: $msg}])
                else
                    .
                end
            )
        )
    ' --arg phase "$phase" --arg ts "$timestamp" --arg msg "$message"
}

record_decision_rationale() {
    local key="$1"
    local detail="$2"
    local timestamp=$(date -Iseconds)

    update_state_file '
        .plan.rationale = (
            ((.plan.rationale // []) + [{key: $key, detail: $detail, timestamp: $ts}])
        )
    ' --arg key "$key" --arg detail "$detail" --arg ts "$timestamp"
}

record_discovery_snapshot() {
    local sample="$1"
    local text_length="$2"
    local structure_json="$3"
    local scanned_at="$4"
    local filename_dates_json="${5:-}"

    if [[ -z "$structure_json" ]]; then
        structure_json='{"categories":[]}'
    fi
    local cleaned_structure
    if ! cleaned_structure=$(printf '%s' "$structure_json" | jq -c '.' 2>/dev/null); then
        log_warn "Folder structure snapshot invalid JSON; defaulting to empty structure"
        cleaned_structure='{"categories":[]}'
    fi

    local structure_tmp
    structure_tmp=$(mktemp -t pdf-structure-snapshot.XXXXXX.json)
    printf '%s' "$cleaned_structure" >"$structure_tmp"

    local filename_dates_clean='[]'
    if [[ -n "$filename_dates_json" ]]; then
        if filename_dates_clean=$(printf '%s' "$filename_dates_json" | jq -c '.' 2>/dev/null); then
            :
        else
            log_warn "Filename date candidates invalid JSON; defaulting to empty list"
            filename_dates_clean='[]'
        fi
    fi

    update_state_file '
        .context.scannedTimestamp = (if $scan == "" then null else $scan end) |
        .context.textSample = $sample |
        .context.textCharacters = ($length|tonumber) |
        .context.folderStructure = ($structure[0] // {categories: []}) |
        .context.filenameDates = $filename_dates
    ' --arg sample "$sample" --arg length "$text_length" --arg scan "$scanned_at" --slurpfile structure "$structure_tmp" --argjson filename_dates "$filename_dates_clean"

    rm -f "$structure_tmp"
}

record_ai_plan_state() {
    local response="$1"
    local organizer_desc="${2:-}"
    local file_desc="${3:-}"
    local analysis categorization destination
    analysis=$(echo "$response" | jq '.analysis // {}')
    categorization=$(echo "$response" | jq '.categorization // {}')
    destination=$(echo "$response" | jq '(.folderSuggestions // {}) | {
        category: (.suggestedCategory // null),
        sender: (.suggestedSender // null),
        department: (.suggestedDepartment // null),
        additionalContext: (.suggestedAdditionalContext // null),
        rationale: (.reasoning // null)
    }')

    if [[ -n "$organizer_desc" ]]; then
        categorization=$(printf '%s' "$categorization" | jq --arg organizer "$organizer_desc" '.organizerDescription = (if $organizer == "" then null else $organizer end)')
    fi

    if [[ -n "$file_desc" ]]; then
        categorization=$(printf '%s' "$categorization" | jq --arg fname "$file_desc" '.fileNameDescription = (if $fname == "" then null else $fname end)')
    fi

    update_state_file '
        .plan.rawResponse = $raw |
        .plan.analysis = $analysis |
        .plan.categorization = $categorization |
        .plan.destination = $destination |
        .plan.confidence = ($analysis.confidence // null) |
        .context.sentOn = ($categorization.sentOn // null) |
        .context.additionalContext = ($categorization.additionalContext // null) |
        .context.organizerDescription = ($categorization.organizerDescription // null) |
        .context.fileNameDescription = ($categorization.fileNameDescription // null)
    ' --argjson raw "$response" --argjson analysis "$analysis" --argjson categorization "$categorization" --argjson destination "$destination"
}

persist_state_document() {
    log_divider "AGENTIC STATE"
    if [[ -n "$STATE_FILE" ]]; then
        mkdir -p "$(dirname "$STATE_FILE")"
        cp "$WORK_STATE_FILE" "$STATE_FILE"
        log_info "Agentic plan saved to $STATE_FILE"
    else
        STATE_FILE="$WORK_STATE_FILE"
        local suggested_path
        suggested_path="$(dirname "$PDF_FILE")/$DEFAULT_STATE_FILENAME"
        log_info "Agentic plan recorded at $STATE_FILE (use --state-file $suggested_path to persist alongside the PDF)"
        if (( DRY_RUN )); then
            log_info "Dry-run requested; emitting agentic plan JSON below"
            cat "$STATE_FILE"
        fi
    fi
}

build_folder_structure_snapshot() {
    local base_path="$PAPERWORK_DIR"
    if [[ ! -d "$base_path" ]]; then
        echo '{"categories":[]}'
        return
    fi

    local cache_key cache_file now modified
    cache_key=$(printf '%s' "$base_path" | cksum | awk '{print $1}')
    cache_file="$CACHE_DIR/folder-structure-$cache_key.json"
    now=$(date +%s)

    if [[ -f "$cache_file" ]]; then
        modified=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        if (( now - modified < STRUCTURE_CACHE_TTL )); then
            cat "$cache_file"
            return
        fi
    fi

    local structure_file
    structure_file=$(mktemp -t pdf-structure.XXXXXX.json)
    jq -n '{categories: []}' >"$structure_file"

    for category in "$base_path"/*; do
        [[ -d "$category" ]] || continue
        local category_name="$(basename "$category")"
        [[ "$category_name" == _* ]] && continue

        local category_count
        category_count=$(find "$category" -type f 2>/dev/null | wc -l | tr -d ' ')
        local category_json
        category_json=$(jq -n --arg name "$category_name" --arg path "$category" --arg count "$category_count" '{name: $name, path: $path, itemCount: ($count|tonumber), senders: []}')

        for sender in "$category"/*; do
            [[ -d "$sender" ]] || continue
            local sender_name="$(basename "$sender")"
            [[ "$sender_name" == _* ]] && continue

            local sender_count
            sender_count=$(find "$sender" -type f 2>/dev/null | wc -l | tr -d ' ')
            local sender_json
            sender_json=$(jq -n --arg name "$sender_name" --arg path "$sender" --arg count "$sender_count" '{name: $name, path: $path, itemCount: ($count|tonumber), departments: []}')

            for department in "$sender"/*; do
                [[ -d "$department" ]] || continue
                local dept_name="$(basename "$department")"
                [[ "$dept_name" == _* ]] && continue
                local dept_count
                dept_count=$(find "$department" -type f 2>/dev/null | wc -l | tr -d ' ')
                local dept_json
                dept_json=$(jq -n --arg name "$dept_name" --arg path "$department" --arg count "$dept_count" '{name: $name, path: $path, itemCount: ($count|tonumber)}')
                sender_json=$(jq --argjson dept "$dept_json" '.departments += [$dept]' <<<"$sender_json")
            done

            category_json=$(jq --argjson sender_json "$sender_json" '.senders += [$sender_json]' <<<"$category_json")
        done

        local updated=$(mktemp -t pdf-structure-cat.XXXXXX.json)
        jq --argjson category "$category_json" '.categories += [$category]' "$structure_file" >"$updated"
        mv "$updated" "$structure_file"
    done

    local structure_json
    structure_json=$(cat "$structure_file")
    rm -f "$structure_file"

    if [[ -n "$structure_json" ]]; then
        local tmp_cache="$cache_file.tmp"
        printf '%s' "$structure_json" >"$tmp_cache"
        mv "$tmp_cache" "$cache_file"
    fi

    printf '%s' "$structure_json"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

set_finder_comments() {
    local file_path="$1"
    local comment="$2"
    osascript -e 'on run {f, c}' -e 'tell app "Finder" to set comment of (POSIX file f as alias) to c' -e end "file://$file_path" "$comment"
}

get_file_creation_date() {
    local file_path="$1"
    local created=""

    # macOS birthtime via BSD stat
    if created=$(stat -f %SB -t %Y-%m-%d "$file_path" 2>/dev/null); then
        if [[ -n "$created" && "$created" != "-" ]]; then
            printf '%s\n' "$created"
            return
        fi
    fi

    # GNU stat creation time
    if created=$(stat -c %w "$file_path" 2>/dev/null); then
        if [[ -n "$created" && "$created" != "-" ]]; then
            created="${created%% *}"
            printf '%s\n' "$created"
            return
        fi
    fi

    # macOS modification timestamp fallback
    if created=$(stat -f %Sm -t %Y-%m-%d "$file_path" 2>/dev/null); then
        printf '%s\n' "$created"
        return
    fi

    # GNU stat modification timestamp fallback
    if created=$(stat -c %y "$file_path" 2>/dev/null); then
        created="${created%% *}"
        printf '%s\n' "$created"
        return
    fi

    if created=$(date -r "$file_path" +%Y-%m-%d 2>/dev/null); then
        printf '%s\n' "$created"
        return
    fi

    date +%Y-%m-%d
}

collect_filename_date_candidates() {
    local file_path="$1"
    local base_name
    base_name="$(basename "$file_path")"

    if [[ -z "$base_name" ]]; then
        echo '[]'
        return
    fi

    local awk_output
    awk_output=$(printf '%s\n' "$base_name" | awk '
function emit(raw, normalized, precision, pattern) {
    printf "%s|%s|%s|%s\n", raw, normalized, precision, pattern
}
{
    line=$0
    len=length(line)
    for (i=1; i<=len; i++) {
        subline=substr(line, i)

        if (match(subline, /^[0-9]{4}[-_/][0-9]{2}[-_/][0-9]{2}/)) {
            raw=substr(subline, 1, RLENGTH)
            normalized=raw
            gsub(/[_/]/, "-", normalized)
            emit(raw, normalized, "day", "separator-day")
        }

        if (match(subline, /^[0-9]{8}/)) {
            raw=substr(subline, 1, 8)
            prev=(i==1) ? "" : substr(line, i-1, 1)
            next=(i+8>len) ? "" : substr(line, i+8, 1)
            if (!(prev ~ /[0-9]/ || next ~ /[0-9]/)) {
                normalized=sprintf("%s-%s-%s", substr(raw,1,4), substr(raw,5,2), substr(raw,7,2))
                emit(raw, normalized, "day", "compact-day")
            }
        }

        if (match(subline, /^[0-9]{4}[-_/][0-9]{2}/)) {
            raw=substr(subline, 1, RLENGTH)
            next_index=i+RLENGTH
            next_char=(next_index <= len) ? substr(line, next_index, 1) : ""
            if (!(next_char ~ /^[-_/0-9]/)) {
                normalized=raw
                gsub(/[_/]/, "-", normalized)
                normalized=substr(normalized, 1, 7)
                emit(raw, normalized, "month", "separator-month")
            }
        }

        if (match(subline, /^[0-9]{6}/)) {
            raw=substr(subline, 1, 6)
            prev=(i==1) ? "" : substr(line, i-1, 1)
            next=(i+6>len) ? "" : substr(line, i+6, 1)
            if (!(prev ~ /[0-9]/ || next ~ /[0-9]/)) {
                normalized=sprintf("%s-%s", substr(raw,1,4), substr(raw,5,2))
                emit(raw, normalized, "month", "compact-month")
            }
        }
    }
}
')

    typeset -A seen=()
    local -a entries=()
    local raw normalized precision pattern key

    while IFS='|' read -r raw normalized precision pattern; do
        [[ -z "$raw" ]] && continue
        key="${normalized}|${precision}"
        if [[ -n "${seen[$key]-}" ]]; then
            continue
        fi
        seen[$key]=1
        entries+=("$raw|$normalized|$precision|$pattern")
    done <<<"$awk_output"

    if (( ${#entries[@]} == 0 )); then
        echo '[]'
        return
    fi

    printf '%s\n' "${entries[@]}" | jq -R -s 'split("\n") | map(select(length>0)) | map(split("|")) | map({raw: .[0], normalized: .[1], precision: .[2], pattern: .[3]})'
}

extract_scanned_timestamp() {
    local filename="$1"
    log_debug "Extracting scanned timestamp from filename: $filename"

    # Try new format first: scan-YYYYMMDD (e.g., scan-20231206)
    local new_format_match
    new_format_match=$(echo "$filename" | grep -oE 'scan-([0-9]{8})' | sed 's/scan-//' || true)
    log_debug "New format scan-YYYYMMDD pattern search result: '$new_format_match'"

    if [[ -n "$new_format_match" ]]; then
        log_info "Found new format timestamp pattern: scan-$new_format_match"
        local year="${new_format_match:0:4}"
        local month="${new_format_match:4:2}"
        local day="${new_format_match:6:2}"
        local formatted_timestamp="${year}-${month}-${day}T00-00-00"
        log_info "Converted new format timestamp to: $formatted_timestamp"
        echo "$formatted_timestamp"
        return 0
    fi

    log_debug "New format not found, trying old format: YYYY-MM-DD[T]HH-MM-SS"
    local old_format_match
    old_format_match=$(echo "$filename" |
        grep -oE '([0-9]{4})-([0-9]{2})-([0-9]{2})[-T]([0-9]{2})-([0-9]{2})-([0-9]{2})' |
        sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)[-T]\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1-\2-\3T\4-\5-\6/' || true)
    log_debug "Old format YYYY-MM-DD[T]HH-MM-SS pattern search result: '$old_format_match'"

    if [[ -n "$old_format_match" ]]; then
        log_info "Found old format timestamp: $old_format_match"
        echo "$old_format_match"
        return 0
    fi

    log_warn "No timestamp pattern found in filename: $filename"
    log_warn "Expected patterns: 'scan-YYYYMMDD' or 'YYYY-MM-DD[T]HH-MM-SS'"
    echo ""
    return 1
}

generate_concise_description() {
    local candidate="$1"
    local fallback="$2"
    local limit="${3:-100}"

    local text="$candidate"
    if [[ -z "$text" || "$text" == "null" ]]; then
        text="$fallback"
    fi

    if [[ -z "$text" || "$text" == "null" ]]; then
        text="Document"
    fi

    text=${text//$'\r'/ }
    text=${text//$'\n'/ }
    text=${text//$'\t'/ }
    # shellcheck disable=SC2001
    text=$(printf '%s' "$text" | sed -e 's/  */ /g' -e 's/^ //; s/ $//')

    if (( ${#text} > limit )); then
        local truncated="${text:0:limit}"
        if [[ "${text:limit:1}" != "" && "${text:limit:1}" != " " ]]; then
            truncated="${truncated% *}"
        fi
        [[ -z "$truncated" ]] && truncated="${text:0:limit}"
        text="${truncated}..."
    fi

    printf '%s' "$text"
}

is_acronym_word() {
    local word="${1//[^A-Za-z0-9]/}"
    if (( ${#word} > 1 )) && [[ "$word" == "${word:u}" ]]; then
        return 0
    fi
    return 1
}

title_case_word() {
    local word="$1"
    if [[ -z "$word" ]]; then
        printf ''
        return
    fi

    if is_acronym_word "$word"; then
        printf '%s' "${word:u}"
        return
    fi

    local first="${word[1,1]}"
    local rest="${word[2,-1]}"
    printf '%s%s' "${first:u}" "${rest:l}"
}

title_case_token() {
    local token="$1"
    local -a parts
    parts=("${(@s:-:)token}")
    local -a title_parts=()
    local part
    for part in "${parts[@]}"; do
        title_parts+=("$(title_case_word "$part")")
    done
    printf '%s' "${(j:-:)title_parts}"
}

title_case_phrase() {
    local text="$1"
    if [[ -z "$text" || "$text" == "null" ]]; then
        echo ""
        return
    fi

    text="${text//$'\r'/ }"
    text="${text//$'\n'/ }"
    text="${text//$'\t'/ }"
    text=$(printf '%s' "$text" | sed -e 's/  */ /g' -e 's/^ //; s/ $//')

    if [[ -z "$text" ]]; then
        echo ""
        return
    fi

    local -a words title_words
    words=("${(z)text}")
    local word
    for word in "${words[@]}"; do
        title_words+=("$(title_case_token "$word")")
    done

    printf '%s' "${(j: :)title_words}"
}

format_spotlight_summary() {
    local summary="$1"
    if [[ -z "$summary" || "$summary" == "null" ]]; then
        echo ""
        return
    fi

    summary="${summary//$'\r'/ }"
    summary="${summary//$'\n'/ }"
    summary="${summary//$'\t'/ }"
    summary=$(printf '%s' "$summary" | sed -e 's/  */ /g' -e 's/^ //; s/ $//')
    printf '%s' "$summary"
}

generate_file_name_description() {
    local primary="$1"
    local fallback="$2"
    local limit="${3:-120}"
    local text="$primary"

    if [[ -z "$text" || "$text" == "null" ]]; then
        text="$fallback"
    fi

    if [[ -z "$text" || "$text" == "null" ]]; then
        text="Document"
    fi

    text=$(title_case_phrase "$text")
    [[ -z "$text" ]] && text="Document"

    if (( ${#text} > limit )); then
        local truncated="${text:0:limit}"
        if [[ "${text:limit:1}" != "" && "${text:limit:1}" != " " ]]; then
            truncated="${truncated% *}"
        fi
        [[ -z "$truncated" ]] && truncated="${text:0:limit}"
        text="$truncated"
    fi

    printf '%s' "$text"
}

validate_required_fields() {
    local sender="$1"
    local category="$2"
    local short_summary="$3"
    local organizer_description="$4"

    if [[ -z "$sender" || "$sender" == "null" ]] ||
        [[ -z "$category" || "$category" == "null" ]] ||
        [[ -z "$short_summary" || "$short_summary" == "null" ]] ||
        [[ -z "$organizer_description" || "$organizer_description" == "null" ]]; then
        log_error "One or more required fields are empty or null"
        log_error "SENDER: '$sender', CATEGORY: '$category', SHORT_SUMMARY: '$short_summary', ORGANIZER_DESCRIPTION: '$organizer_description'"
        return 1
    fi
    return 0
}

check_confidence_level() {
    local confidence="$1"

    if command -v bc >/dev/null 2>&1 && [[ "$confidence" != "null" ]]; then
        if [[ $(echo "$confidence < 0.7" | bc) -eq 1 ]]; then
            log_warn "AI confidence is low ($confidence). Manual review may be needed."
        fi
    fi
}

# ============================================================================
# PDF TEXT EXTRACTION FUNCTIONS
# ============================================================================

extract_pdf_text() {
    local pdf_file="$1"

    log_info "Extracting text from PDF file"
    local text
    text=$(get-pdf-text "$pdf_file")

    if [[ -z "$text" ]]; then
        log_warn "Initial text extraction failed, attempting OCR processing..."
        text=$(extract_text_with_ocr "$pdf_file")
    fi

    if [[ -z "$text" ]]; then
        log_error "Failed to extract text from PDF file"
        exit 1
    fi

    log_debug "Successfully extracted PDF text (${#text} characters)"

    # Limit text length to prevent API issues
    if [[ ${#text} -gt $MAX_PDF_TEXT_LENGTH ]]; then
        log_warn "PDF text is very long (${#text} chars), truncating to prevent API issues"
        text="${text:0:$MAX_PDF_TEXT_LENGTH}... [TRUNCATED]"
    fi

    echo "$text"
}

extract_text_with_ocr() {
    local pdf_file="$1"

    if [[ ! -f "$OCR_SCRIPT" ]]; then
        log_error "OCR script not found at $OCR_SCRIPT"
        return 1
    fi

    log_info "Running OCR processing on PDF: $OCR_SCRIPT"
    if "$OCR_SCRIPT" "$pdf_file"; then
        log_info "OCR processing completed, retrying text extraction"
        local text
        text=$(get-pdf-text "$pdf_file")

        if [[ -z "$text" ]]; then
            log_error "Failed to extract text even after OCR processing"
            return 1
        else
            log_info "Successfully extracted text after OCR processing"
            echo "$text"
        fi
    else
        log_error "OCR processing failed"
        return 1
    fi
}

prepare_folder_structure_context() {
    log_info "Analyzing existing folder structure"
    local structure
    structure=$(build_folder_structure_snapshot)

    if [[ -z "$structure" || "$structure" == '{"categories":[]}' ]]; then
        log_info "No existing folder structure found - this will be a new organization"
        echo '{"categories":[]}'
    else
        log_debug "Folder structure for AI context: $structure"
        printf '%s' "$structure"
    fi
}

# ============================================================================
# AI PROCESSING FUNCTIONS
# ============================================================================

# Comprehensive AI processing function optimized for GPT-4o
process_pdf_with_ai() {
    local state_snapshot="$1"
    local compact_state
    compact_state=$(printf '%s' "$state_snapshot" | jq -c '.')

    local system_message
    system_message="You are an expert paperwork operations agent inside a sequential workflow. The JSON you receive contains the current discovery state for a single PDF (metadata, file facts, and derived context). Use it to:

1. Analyze the document and list what it represents and who sent it.
2. Recommend consistent folder/category placements using the discovered archive structure.
3. Produce a short summary plus any identifying metadata (dates, account numbers, case numbers, etc.).

Guidelines:
- Always reuse existing folder/category/sender names when the archive snapshot already contains a close match.
- Prefer translating names to a consistent English form.
- Departments are only for government entities or when explicitly called out.
- Consider context.filenameDates (normalized dates parsed from the filename) when proposing sentOn or describing the document timeline; treat these as hints that may need validation against the PDF text.
- Include an organizerDescription inside categorization that is a plain-English label (<=100 characters) suitable for file naming.
- Short summaries are stored verbatim in macOS Finder comments; write a natural-sentence paragraph rich with relevant keywords to maximize Spotlight searchability (do not force title case).
- Return JSON that follows the provided schema exactly; do not add new keys.
- Provide reasoning that cites the contextual evidence you relied on."

    local user_message
    user_message="Current workflow state JSON:\n$compact_state\n\nUpdate the plan according to the schema."

    local json_payload
    json_payload=$(jq -n \
        --arg system_msg "$system_message" \
        --arg user_msg "$user_message" \
        '{
            "messages": [
                {
                    "role": "system",
                    "content": $system_msg
                },
                {
                    "role": "user",
                    "content": $user_msg
                }
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "ComprehensiveFileSystemCategorization",
                    "strict": true,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "analysis": {
                                "type": "object",
                                "properties": {
                                    "documentType": {"type": "string"},
                                    "primarySender": {"type": "string"},
                                    "existingFolderMatch": {"type": ["string", "null"]},
                                    "confidence": {"type": "number", "minimum": 0, "maximum": 1}
                                },
                                "required": ["documentType", "primarySender", "existingFolderMatch", "confidence"],
                                "additionalProperties": false
                            },
                            "categorization": {
                                "type": "object",
                                "properties": {
                                    "sender": {"type": "string"},
                                    "department": {"type": ["string", "null"]},
                                    "additionalContext": {"type": ["string", "null"]},
                                    "sentOn": {"type": "string"},
                                    "category": {"type": "string"},
                                    "shortSummary": {"type": "string"},
                                    "organizerDescription": {"type": "string", "description": "<=100 char label for file organization"}
                                },
                                "required": ["sender", "department", "additionalContext", "sentOn", "category", "shortSummary", "organizerDescription"],
                                "additionalProperties": false
                            },
                            "folderSuggestions": {
                                "type": "object",
                                "properties": {
                                    "suggestedCategory": {"type": ["string", "null"]},
                                    "suggestedSender": {"type": ["string", "null"]},
                                    "suggestedDepartment": {"type": ["string", "null"]},
                                    "suggestedAdditionalContext": {"type": ["string", "null"]},
                                    "reasoning": {"type": "string"}
                                },
                                "required": ["suggestedCategory", "suggestedSender", "suggestedDepartment", "suggestedAdditionalContext", "reasoning"],
                                "additionalProperties": false
                            }
                        },
                        "required": ["analysis", "categorization", "folderSuggestions"],
                        "additionalProperties": false
                    }
                }
            }
        }')

    get-openai-response "$json_payload"
}

validate_ai_response() {
    local response="$1"

    if [[ -z "$response" ]]; then
        log_error "AI response is empty. Check API connectivity and credentials."
        exit 1
    fi

    # Check if response contains error information
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        local ai_error
        ai_error=$(echo "$response" | jq -r '.error')
        log_error "AI API returned error: $ai_error"
        exit 1
    fi
}

extract_categorization_data() {
    local response="$1"

    log_debug "Parsing comprehensive AI response"

    # Extract categorization data
    local sender department additional_context sent_on category short_summary organizer_description
    sender=$(echo "$response" | jq -r '.categorization.sender')
    department=$(echo "$response" | jq -r '.categorization.department')
    additional_context=$(echo "$response" | jq -r '.categorization.additionalContext')
    sent_on=$(echo "$response" | jq -r '.categorization.sentOn' | tr '/: ' '-')
    category=$(echo "$response" | jq -r '.categorization.category')
    short_summary=$(echo "$response" | jq -r '.categorization.shortSummary' | tr '"' "'")
    organizer_description=$(echo "$response" | jq -r '.categorization.organizerDescription')

    # Handle null values
    if [[ "$department" == "null" ]]; then
        department=""
    fi
    if [[ "$additional_context" == "null" ]]; then
        additional_context=""
    fi

    organizer_description=$(generate_concise_description "$organizer_description" "$short_summary" 100)

    short_summary=$(format_spotlight_summary "$short_summary")
    if [[ -z "$short_summary" || "$short_summary" == "null" ]]; then
        short_summary=$(format_spotlight_summary "$organizer_description")
    fi
    if [[ -z "$short_summary" || "$short_summary" == "null" ]]; then
        short_summary="Document summary pending manual input."
    fi

    local file_name_desc
    file_name_desc=$(generate_file_name_description "$organizer_description" "$short_summary" 120)

    # Set global variables for use in other functions
    declare -g SENDER="$sender"
    declare -g DEPARTMENT="$department"
    declare -g ADDITIONAL_CONTEXT="$additional_context"
    declare -g SENT_ON="$sent_on"
    declare -g CATEGORY="$category"
    declare -g SHORT_SUMMARY="$short_summary"
    declare -g ORGANIZER_DESCRIPTION="$organizer_description"
    declare -g FILE_NAME_DESCRIPTION="$file_name_desc"
}

apply_ai_suggestions() {
    local response="$1"

    # Extract AI suggestions and analysis
    local suggested_category suggested_sender suggested_department suggested_additional_context ai_reasoning confidence
    local primary_sender existing_folder_match

    suggested_category=$(echo "$response" | jq -r '.folderSuggestions.suggestedCategory')
    suggested_sender=$(echo "$response" | jq -r '.folderSuggestions.suggestedSender')
    suggested_department=$(echo "$response" | jq -r '.folderSuggestions.suggestedDepartment')
    suggested_additional_context=$(echo "$response" | jq -r '.folderSuggestions.suggestedAdditionalContext')
    ai_reasoning=$(echo "$response" | jq -r '.folderSuggestions.reasoning')
    confidence=$(echo "$response" | jq -r '.analysis.confidence')

    # Extract simplified analysis data
    primary_sender=$(echo "$response" | jq -r '.analysis.primarySender')
    existing_folder_match=$(echo "$response" | jq -r '.analysis.existingFolderMatch')

    log_info "AI Analysis Results:"
    log_info "  Primary Sender Identified: $primary_sender"
    log_info "  Existing Folder Match: $existing_folder_match"
    log_info "  Categorization - SENDER: $SENDER, CATEGORY: $CATEGORY, DEPARTMENT: $DEPARTMENT, ORGANIZER_DESCRIPTION: $ORGANIZER_DESCRIPTION, ADDITIONAL_CONTEXT: $ADDITIONAL_CONTEXT"
    log_info "  Suggestions - Category: $suggested_category, Sender: $suggested_sender, Department: $suggested_department, Additional Context: $suggested_additional_context"
    log_info "  Confidence: $confidence, Reasoning: $ai_reasoning"

    # Prioritize existing folder matches for sender consistency
    if [[ "$existing_folder_match" != "null" && -n "$existing_folder_match" ]]; then
        if [[ "$existing_folder_match" == "$CATEGORY" ]]; then
            log_debug "Existing folder match equals category '$CATEGORY'; keeping sender as '$SENDER'"
        else
            log_info "Using existing folder match for sender consistency: $existing_folder_match"
            SENDER="$existing_folder_match"
        fi
    elif [[ "$suggested_sender" != "null" && -n "$suggested_sender" ]]; then
        log_info "Using AI suggested sender: $suggested_sender (instead of: $SENDER)"
        SENDER="$suggested_sender"
    fi

    # Use AI suggestions when they provide better matches
    if [[ "$suggested_category" != "null" && -n "$suggested_category" ]]; then
        log_info "Using AI suggested category: $suggested_category (instead of: $CATEGORY)"
        CATEGORY="$suggested_category"
    fi

    if [[ "$suggested_department" != "null" && -n "$suggested_department" ]]; then
        log_info "Using AI suggested department: $suggested_department (instead of: $DEPARTMENT)"
        DEPARTMENT="$suggested_department"
    fi

    if [[ "$suggested_additional_context" != "null" && -n "$suggested_additional_context" ]]; then
        log_info "Using AI suggested additional context: $suggested_additional_context (instead of: $ADDITIONAL_CONTEXT)"
        ADDITIONAL_CONTEXT="$suggested_additional_context"
    fi

    check_confidence_level "$confidence"

    log_debug "Final parsed values - SENDER: $SENDER, DEPARTMENT: $DEPARTMENT, ADDITIONAL_CONTEXT: $ADDITIONAL_CONTEXT, ORGANIZER_DESCRIPTION: $ORGANIZER_DESCRIPTION, SENT_ON: $SENT_ON, CATEGORY: $CATEGORY"
}

# ============================================================================
# FOLDER MANAGEMENT FUNCTIONS
# ============================================================================

create_folder_structure() {
    local category="$1"
    local sender="$2"
    local department="$3"

    local category_dir="$PAPERWORK_DIR/$category"
    local sender_dir="$category_dir/$sender"
    local final_dir="$sender_dir"

    # Create category directory if it doesn't exist
    if [[ ! -d "$category_dir" ]]; then
        log_info "Creating new category folder: $category_dir"
        mkdir -p "$category_dir"
    else
        log_debug "Category folder already exists: $category_dir"
    fi

    # Create sender directory if it doesn't exist
    if [[ ! -d "$sender_dir" ]]; then
        log_info "Creating sender folder: $sender_dir"
        mkdir -p "$sender_dir"
    else
        log_debug "Sender folder already exists: $sender_dir"
    fi

    # Handle department folder if specified
    if [[ -n "$department" ]]; then
        local department_dir="$sender_dir/$department"
        if [[ ! -d "$department_dir" ]]; then
            log_info "Creating department folder: $department_dir"
            mkdir -p "$department_dir"
        else
            log_debug "Department folder already exists: $department_dir"
        fi
        final_dir="$department_dir"
    fi

    echo "$final_dir"
}

resolve_primary_document_date() {
    PRIMARY_DATE_SOURCE=""
    PRIMARY_DATE_REASON=""
    local letter_date="$SENT_ON"
    if [[ -n "$letter_date" && "$letter_date" != "null" ]]; then
        PRIMARY_DATE_SOURCE="letter_date"
        PRIMARY_DATE_REASON="AI provided sentOn date $letter_date"
        printf '%s\n' "$letter_date"
        return
    fi

    if [[ -n "$FILE_CREATED_AT" ]]; then
        PRIMARY_DATE_SOURCE="file_created_at"
        PRIMARY_DATE_REASON="Using filesystem creation date $FILE_CREATED_AT because no sentOn was provided"
        printf '%s\n' "$FILE_CREATED_AT"
        return
    fi

    if [[ -n "$SCANNED_AT" ]]; then
        local scan_date="${SCANNED_AT%%T*}"
        PRIMARY_DATE_SOURCE="scanned_at"
        PRIMARY_DATE_REASON="Falling back to scan timestamp parsed from filename ($SCANNED_AT)"
        printf '%s\n' "$scan_date"
        return
    fi

    local today
    today=$(date +%Y-%m-%d)
    PRIMARY_DATE_SOURCE="current_date"
    PRIMARY_DATE_REASON="No reliable date hints were available; defaulting to today's date ($today)"
    printf '%s\n' "$today"
}

generate_unique_filename() {
    local destination_dir="$1"
    local sender_sanitized="$2"
    local department_sanitized="$3"
    local descriptor_sanitized="$4"
    local primary_date="$5"

    local max_filename_length=255
    local date_component="$primary_date"
    [[ -z "$date_component" || "$date_component" == "null" ]] && date_component=$(date +%Y-%m-%d)

    local descriptor="$sender_sanitized"
    descriptor+="$department_sanitized"
    descriptor+="$descriptor_sanitized"
    [[ -z "$descriptor" ]] && descriptor="Document"

    local base_filename="${date_component}_${descriptor}.pdf"

    if [[ ${#base_filename} -gt $max_filename_length ]]; then
        log_warn "Filename too long (${#base_filename} chars), tightening components"

        if [[ -n "$descriptor_sanitized" ]]; then
            descriptor="$sender_sanitized$department_sanitized"
            base_filename="${date_component}_${descriptor}.pdf"
        fi

        if [[ ${#base_filename} -gt $max_filename_length && -n "$department_sanitized" ]]; then
            descriptor="$sender_sanitized"
            base_filename="${date_component}_${descriptor}.pdf"
        fi

        if [[ ${#base_filename} -gt $max_filename_length && -n "$sender_sanitized" ]]; then
            local available_length=$((max_filename_length - ${#date_component} - 1 - 4))
            descriptor="${sender_sanitized:0:$available_length}"
            [[ -z "$descriptor" ]] && descriptor="Doc"
            base_filename="${date_component}_${descriptor}.pdf"
        fi

        if [[ ${#base_filename} -gt $max_filename_length ]]; then
            base_filename="${date_component}.pdf"
            log_warn "Falling back to minimal filename: $base_filename"
        fi
    fi

    local new_file="$destination_dir/$base_filename"
    local counter=1
    while [[ -e "$new_file" ]]; do
        local counter_suffix="-$(printf "%03d" $counter)"
        local base_without_extension="${base_filename%.pdf}"
        local candidate="${base_without_extension}${counter_suffix}.pdf"

        if [[ ${#candidate} -gt $max_filename_length ]]; then
            local extension=".pdf"
            local available_for_base=$((max_filename_length - ${#counter_suffix} - ${#extension}))
            base_without_extension="${base_without_extension:0:$available_for_base}"
            candidate="${base_without_extension}${counter_suffix}${extension}"
        fi

        new_file="$destination_dir/$candidate"
        counter=$((counter + 1))
    done

    echo "$new_file"
}

# ============================================================================
# FILE PROCESSING FUNCTIONS
# ============================================================================

prepare_initial_data() {
    log_info "Starting PDF organization for: $(basename "$PDF_FILE")"
    record_phase_start "discovery"
    record_phase_note "discovery" "Beginning context discovery for $(basename "$PDF_FILE")"

    FILE_CREATED_AT=$(get_file_creation_date "$PDF_FILE" || true)
    update_state_file '
        .file.createdAt = (if $created == "" then null else $created end) |
        .context.createdTimestamp = (if $created == "" then null else $created end)
    ' --arg created "$FILE_CREATED_AT"
    if [[ -n "$FILE_CREATED_AT" ]]; then
        log_info "File creation date detected: $FILE_CREATED_AT"
        record_phase_note "discovery" "Captured file creation date $FILE_CREATED_AT"
    fi

    # Extract the date from the filename (should be in format 2023-12-06T10-40-27)
    log_debug "Attempting to extract scanned timestamp from filename"
    SCANNED_AT=$(extract_scanned_timestamp "$PDF_FILE" || true)
    if [[ -z "$SCANNED_AT" ]]; then
        log_warn "No scan timestamp located in filename; relying on other date sources"
        record_phase_note "discovery" "Filename missing scan timestamp pattern"
    else
        log_info "Successfully extracted scanned timestamp: $SCANNED_AT"
        record_phase_note "discovery" "Parsed scan timestamp $SCANNED_AT from filename"
    fi

    local filename_date_candidates
    filename_date_candidates=$(collect_filename_date_candidates "$PDF_FILE" || echo '[]')
    if [[ -n "$filename_date_candidates" && "$filename_date_candidates" != "[]" ]]; then
        local candidate_count
        candidate_count=$(printf '%s' "$filename_date_candidates" | jq 'length' 2>/dev/null || echo 0)
        record_phase_note "discovery" "Identified $candidate_count filename date hint(s)"
    fi

    # Extract text from PDF
    log_info "Proceeding with PDF text extraction"
    PDF_TEXT=$(extract_pdf_text "$PDF_FILE")
    log_debug "PDF text length: ${#PDF_TEXT} characters"

    # Get comprehensive folder structure for AI context
    FOLDER_STRUCTURE=$(prepare_folder_structure_context)
    local state_structure="$FOLDER_STRUCTURE"
    if [[ -z "$state_structure" ]]; then
        state_structure='{"categories":[]}'
    fi
    local state_sample="$PDF_TEXT"
    if (( ${#state_sample} > AGENTIC_TEXT_SAMPLE_LIMIT )); then
        state_sample="${state_sample:0:AGENTIC_TEXT_SAMPLE_LIMIT} ... [STATE_TRUNCATED]"
    fi
    record_discovery_snapshot "$state_sample" "${#PDF_TEXT}" "$state_structure" "$SCANNED_AT" "$filename_date_candidates"
    record_phase_note "discovery" "Indexed ${#PDF_TEXT} chars of text and captured folder snapshot"
    record_phase_complete "discovery"
}

process_with_ai() {
    log_info "Processing PDF content with comprehensive AI analysis"
    record_phase_start "analysis"

    # Validate inputs before sending to AI
    if [[ -z "$PDF_TEXT" ]]; then
        log_error "PDF text is empty, cannot proceed with AI analysis"
        exit 1
    fi

    log_debug "PDF text length: ${#PDF_TEXT} characters"
    log_debug "Folder structure snapshot length: ${#FOLDER_STRUCTURE} characters"

    local state_snapshot
    state_snapshot=$(jq '{metadata, file, context}' "$WORK_STATE_FILE")
    AI_RESPONSE=$(process_pdf_with_ai "$state_snapshot")
    validate_ai_response "$AI_RESPONSE"

    echo-json "$AI_RESPONSE"

    extract_categorization_data "$AI_RESPONSE"
    apply_ai_suggestions "$AI_RESPONSE"

    record_ai_plan_state "$AI_RESPONSE" "$ORGANIZER_DESCRIPTION" "$FILE_NAME_DESCRIPTION"

    # Validate required fields
    if ! validate_required_fields "$SENDER" "$CATEGORY" "$SHORT_SUMMARY" "$ORGANIZER_DESCRIPTION"; then
        exit 1
    fi

    record_final_plan_outcome
    local document_type
    document_type=$(echo "$AI_RESPONSE" | jq -r '.analysis.documentType // "document"')
    record_decision_rationale "summary" "Short summary sourced from AI analysis of ${document_type}: $SHORT_SUMMARY"
    record_decision_rationale "organizer-description" "Concise organizer description constrained to 100 chars for filenames: $ORGANIZER_DESCRIPTION"
    record_decision_rationale "file-name-description" "File-friendly description used for naming: $FILE_NAME_DESCRIPTION"
    record_phase_note "analysis" "AI selected category '$CATEGORY' and sender '$SENDER'"
    record_phase_complete "analysis"

    log_info "Successfully categorized PDF with AI optimization: Category='$CATEGORY', Sender='$SENDER'"
}

organize_and_move_file() {
    log_info "Preparing final file naming and placement"
    record_phase_start "action"

    local action_verb="copy"
    if [[ "$MOVE_FILE" == true ]]; then
        action_verb="move"
    fi

    # Create folder structure and get destination directory
    local destination_dir
    destination_dir=$(create_folder_structure "$CATEGORY" "$SENDER" "$DEPARTMENT")

    # Create sanitized versions for file names
    local sender_sanitized department_sanitized descriptor_source file_descriptor_sanitized
    sender_sanitized=$(sanitize-text "$SENDER")
    department_sanitized=$(sanitize-text "$DEPARTMENT")
    descriptor_source="$FILE_NAME_DESCRIPTION"
    if [[ -z "$descriptor_source" || "$descriptor_source" == "null" ]]; then
        descriptor_source="$ORGANIZER_DESCRIPTION"
    fi
    file_descriptor_sanitized=$(sanitize-text "$descriptor_source")

    if [[ -n "$department_sanitized" && "$department_sanitized" != "null" ]]; then
        department_sanitized="-${department_sanitized}"
    else
        department_sanitized=""
    fi

    if [[ -n "$file_descriptor_sanitized" && "$file_descriptor_sanitized" != "null" ]]; then
        file_descriptor_sanitized="-${file_descriptor_sanitized}"
    else
        file_descriptor_sanitized=""
    fi

    local primary_document_date
    primary_document_date=$(resolve_primary_document_date)
    if [[ -n "$PRIMARY_DATE_REASON" ]]; then
        log_info "$PRIMARY_DATE_REASON"
        record_decision_rationale "primary-date" "$PRIMARY_DATE_REASON"
        record_phase_note "action" "$PRIMARY_DATE_REASON"
    fi

    # Generate unique filename
    local new_file
    new_file=$(generate_unique_filename "$destination_dir" "$sender_sanitized" "$department_sanitized" "$file_descriptor_sanitized" "$primary_document_date")

    log_info "Final file destination: $(basename "$new_file")"
    log_debug "Full path: $new_file"

    if (( DRY_RUN )); then
        log_info "Dry-run enabled; no filesystem changes will be made"
        record_action_snapshot "$new_file" "" "$SHORT_SUMMARY"
        record_phase_note "action" "Dry-run preview: would $action_verb to $new_file"
        record_phase_complete "action"
        return
    fi

    # Copy or move file to destination based on user preference
    if [[ "$MOVE_FILE" == true ]]; then
        log_info "Moving PDF file to destination"
        mv "$PDF_FILE" "$new_file"
    else
        log_info "Copying PDF file to destination"
        cp "$PDF_FILE" "$new_file"
    fi

    # Set Finder comments with summary
    log_info "Setting Finder comments with summary"
    set_finder_comments "$new_file" "$SHORT_SUMMARY"

    # Open destination folder in Finder
    log_info "Opening destination folder in Finder"
    open "$destination_dir"

    record_action_snapshot "$new_file" "$new_file" "$SHORT_SUMMARY"
    record_phase_note "action" "Completed $action_verb to $new_file"
    record_phase_complete "action"

    log_info "PDF organization completed successfully"
}

# ============================================================================
# MAIN EXECUTION FLOW
# ============================================================================

main() {
    # Initialize and validate
    validate_arguments "$@"
    setup_environment

    # Process the PDF
    prepare_initial_data
    process_with_ai
    organize_and_move_file
    persist_state_document

    log_divider "END OF PROCESSING"
}

# Execute main function with all arguments
main "$@"
