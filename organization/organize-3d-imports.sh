#!/usr/bin/env zsh

# shell safety
setopt extended_glob
setopt null_glob
set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
DEFAULT_STATE_FILENAME="agentic-plan.json"
readonly BASE_PATH="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
DRY_RUN=0
SKIP_AI=0
STATE_FILE=""
INPUT_PATH=""
WORK_STATE_FILE=""
BACKUP_ARCHIVE=""
ORIGINAL_INPUT_PATH=""
FILE_INDEX=0
AI_HELPERS_LOADED=0
DOCUMENTATION_CONTEXT=""
FILE_ENTRIES_BUFFER=""
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/organize-3d-imports"
ARCHIVE_CACHE_TTL=${ARCHIVE_CACHE_TTL:-900}
typeset -A WEBLOC_URL_REGISTRY=()


typeset -a IGNORE_PATTERNS=(
    '.DS_Store'
    '._*'
    'Thumbs.db'
    'desktop.ini'
    "$DEFAULT_STATE_FILENAME"
)

usage() {
    cat <<'USAGE'
Usage: organize-3d-imports.sh [options] <folder>

Options:
  --state-file <path>   Write the JSON state file to this path (default: <folder>/agentic-plan.json)
  --dry-run             Perform analysis and persist state without renaming files
  --skip-ai             Skip the AI planning cycle (state will contain only discovery data)
  -h, --help            Show this help text

The script creates a backup archive, builds a JSON map of every file, runs an
optional AI planning cycle to propose renames, persists the JSON plan, and then
(if not in dry-run mode) applies the proposed rename/move operations.
USAGE
}

extract_webloc_url() {
    local file_path="$1"
    [[ -f "$file_path" ]] || return

    local url=""
    if url=$(/usr/libexec/PlistBuddy -c 'Print :URL' "$file_path" 2>/dev/null); then
        :
    elif url=$(/usr/libexec/PlistBuddy -c 'Print :URLString' "$file_path" 2>/dev/null); then
        :
    else
        url=$(grep -A1 -i '<key>URL' "$file_path" 2>/dev/null | tail -n1 | sed -E 's/<[^>]+>//g' | sed 's/^\s*//;s/\s*$//')
    fi

    printf '%s\n' "${url//$'\r'/}" | sed 's/^ *//;s/ *$//'
}

fetch_url_preview() {
    local url="$1"
    [[ -n "$url" ]] || return

    local html
    html=$(curl -Ls --max-time 15 --retry 1 --retry-all-errors -H 'Accept-Language: en-US,en;q=0.9' -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15' "$url" 2>/dev/null | head -c 50000) || return
    if [[ -z "$html" ]]; then
        log_debug "URL preview fetch returned empty body: $url"
        return
    fi

    local title meta_desc og_desc description preview
    title=$(printf '%s' "$html" | xmllint --html --recover --xpath 'string(//title)' - 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
    meta_desc=$(printf '%s' "$html" | xmllint --html --recover --xpath 'string(//meta[translate(@name,"ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz")="description"]/@content)' - 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
    og_desc=$(printf '%s' "$html" | xmllint --html --recover --xpath 'string(//meta[translate(@property,"ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz")="og:description"]/@content)' - 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')

    description="$meta_desc"
    [[ -z "$description" ]] && description="$og_desc"

    if [[ -n "$title" && -n "$description" ]]; then
        preview="$title — $description"
    elif [[ -n "$title" ]]; then
        preview="$title"
    else
        preview="$description"
    fi

    preview=$(printf '%s' "$preview" | tr -d '\r' | sed 's/^ *//;s/ *$//' | cut -c1-600)

    case "$preview" in
        "Just a moment"*|"Attention Required"*)
            log_debug "URL preview blocked by site challenge: $url"
            return
            ;;
    esac

    [[ -n "$preview" ]] && printf '%s\n' "$preview"
}
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

parse_args() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state-file)
                [[ $# -lt 2 ]] && { echo "--state-file requires a value" >&2; exit 1; }
                STATE_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --skip-ai)
                SKIP_AI=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if (( ${#args[@]} == 0 )); then
        echo "A folder path is required" >&2
        usage
        exit 1
    fi

    INPUT_PATH="${args[1]}"
}

setup_logging() {
    export LOG_LEVEL=0
    export LOG_FD=2
    source "$SCRIPT_DIR/../utilities/logging.sh"
    setup_script_logging
    set_log_level "INFO"
    log_header "organize-3d-imports.sh"
}

ensure_ai_helpers_loaded() {
    if (( AI_HELPERS_LOADED )); then
        return
    fi

    source "$SCRIPT_DIR/../ai/open-ai-functions.sh" || {
        log_error "Failed to source OpenAI helper functions"
        exit 1
    }
    AI_HELPERS_LOADED=1
}

validate_environment() {
    [[ -d "$INPUT_PATH" ]] || { echo "Input path must be an existing directory" >&2; exit 1; }
    INPUT_PATH="$(cd "$INPUT_PATH" &>/dev/null && pwd)"
    ORIGINAL_INPUT_PATH="$INPUT_PATH"

    require_command jq
    require_command zip
    require_command find
    require_command stat
    require_command cmp
    require_command curl
    require_command xmllint

    if [[ -z "$STATE_FILE" ]]; then
        STATE_FILE="$INPUT_PATH/$DEFAULT_STATE_FILENAME"
    fi

    mkdir -p "$BASE_PATH"
    mkdir -p "$CACHE_DIR"
    WORK_STATE_FILE=$(mktemp -t agentic-state.XXXXXX.json)
    FILE_ENTRIES_BUFFER=$(mktemp -t agentic-files.XXXXXX.json)
}

create_backup_archive() {
    log_divider "BACKUP"
    if (( DRY_RUN )); then
        log_info "Dry-run requested; skipping backup archive"
        BACKUP_ARCHIVE=""
        return
    fi

    log_info "Creating backup archive before analysis"

    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local folder_name="$(basename "$INPUT_PATH")"
    local parent_dir="$(dirname "$INPUT_PATH")"
    local backup_name="${folder_name}_backup_${timestamp}.zip"
    BACKUP_ARCHIVE="$INPUT_PATH/$backup_name"

    (cd "$parent_dir" && zip -qr "$folder_name/$backup_name" "$folder_name" -x "$folder_name/$backup_name") && {
        log_info "Backup created at $BACKUP_ARCHIVE"
    } || {
        log_warn "Failed to create backup archive"
        BACKUP_ARCHIVE=""
    }
}

initialize_state_document() {
    log_divider "STATE INIT"
    local generated_at=$(date -Iseconds)
    local folder_name="$(basename "$INPUT_PATH")"

    jq -n \
        --arg schema "1.0" \
        --arg generated "$generated_at" \
        --arg input "$INPUT_PATH" \
        --arg folder "$folder_name" \
        --arg backup "$BACKUP_ARCHIVE" \
        --arg dry "$DRY_RUN" \
        '{
            metadata: {
                schemaVersion: $schema,
                generatedAt: $generated,
                inputPath: $input,
                folderName: $folder,
                backupZip: $backup,
                dryRun: ($dry == "1"),
                totalFiles: 0,
                agentCycles: [],
                duplicates: []
            },
            files: []
        }' >"$WORK_STATE_FILE"
}

classify_extension() {
    local ext="${1:l}"
    case "$ext" in
        stl|obj|3mf|step|stp|f3d|blend|scad|shapr) echo "3d-model" ;;
        gcode) echo "print-export" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) echo "image" ;;
        pdf|md|txt|rtf|html|htm|doc|docx) echo "documentation" ;;
        json|csv|yaml|yml) echo "data" ;;
        *) echo "other" ;;
    esac
}

append_file_entry() {
    local file_path="$1"
    local rel_path="${file_path#$INPUT_PATH/}"
    local filename="$(basename "$file_path")"
    local extension=""
    if [[ "$filename" == *.* ]]; then
        extension="${filename##*.}"
    fi
    local size_bytes
    size_bytes=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
    local category=$(classify_extension "$extension")
    local file_id=$FILE_INDEX
    FILE_INDEX=$((FILE_INDEX + 1))

    local source_url=""
    local link_preview=""
    local url_duplicate_of=""
    if [[ "${extension:l}" == "webloc" ]]; then
        source_url=$(extract_webloc_url "$file_path" || true)
        if [[ -n "$source_url" ]]; then
            link_preview=$(fetch_url_preview "$source_url" || true)
            if [[ -n "${WEBLOC_URL_REGISTRY[$source_url]-}" ]]; then
                url_duplicate_of="${WEBLOC_URL_REGISTRY[$source_url]}"
            else
                WEBLOC_URL_REGISTRY[$source_url]="$file_path"
            fi
        fi
    fi

    local file_json
    file_json=$(jq -n \
        --arg id "$file_id" \
        --arg original "$file_path" \
        --arg relative "$rel_path" \
        --arg name "$filename" \
        --arg ext "${extension:l}" \
        --arg size "$size_bytes" \
        --arg category "$category" \
        --arg source "$source_url" \
        --arg preview "$link_preview" \
        --arg duplicate "$url_duplicate_of" \
        '{
            id: ($id|tonumber),
            originalPath: $original,
            relativePath: $relative,
            filename: $name,
            extension: $ext,
            sizeBytes: ($size|tonumber),
            category: $category,
            sourceUrl: (if $source == "" then null else $source end),
            linkPreview: (if $preview == "" then null else $preview end),
            urlDuplicateOf: (if $duplicate == "" then null else $duplicate end),
            proposed: {
                folder: null,
                filename: null,
                path: null,
                absolutePath: null,
                rationale: null
            },
            agentNotes: []
        }')

    printf '%s\n' "$file_json" >>"$FILE_ENTRIES_BUFFER"
}

finalize_file_inventory() {
    local entries_json="[]"
    if [[ -s "$FILE_ENTRIES_BUFFER" ]]; then
        entries_json=$(jq -s '.' "$FILE_ENTRIES_BUFFER")
    fi

    local tmp=$(mktemp)
    jq --argjson entries "$entries_json" \
        '.files = $entries | .metadata.totalFiles = ($entries | length)' \
        "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"

    record_url_duplicates
}

record_url_duplicates() {
    local tmp=$(mktemp)
    jq '
        .metadata.duplicates += (
            [ .files[]
              | select(.urlDuplicateOf != null)
              | {
                    fileId: .id,
                    originalPath: .originalPath,
                    duplicateOf: .urlDuplicateOf,
                    url: .sourceUrl,
                    type: "url"
                }
            ]
        )
    ' "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

build_file_inventory() {
    log_divider "DISCOVERY"
    log_info "Scanning directory tree for files"

    : >"$FILE_ENTRIES_BUFFER"
    local found_any=0
    while IFS= read -r -d '' file; do
        local base="$(basename "$file")"
        local skip=0
        for pattern in "${IGNORE_PATTERNS[@]}"; do
            if [[ "$base" == $~pattern ]]; then
                skip=1
                break
            fi
        done
        (( skip )) && continue

        append_file_entry "$file"
        found_any=1
    done < <(find "$INPUT_PATH" -type f -print0)

    if (( ! found_any )); then
        log_error "No files discovered in $INPUT_PATH"
        exit 1
    fi
    finalize_file_inventory
    log_info "Indexed $(jq '.metadata.totalFiles' "$WORK_STATE_FILE") files"
}

read_text_from_file() {
    local file_path="$1"
    local extension="${file_path##*.}"
    local lower_ext="${extension:l}"

    case "$lower_ext" in
        pdf)
            if command -v pdftotext >/dev/null 2>&1; then
                pdftotext -nopgbrk -raw "$file_path" - 2>/dev/null || true
            else
                log_warn "pdftotext not available to read $file_path"
            fi
            ;;
        rtf)
            if command -v textutil >/dev/null 2>&1; then
                textutil -convert txt -stdout "$file_path" 2>/dev/null || true
            else
                cat "$file_path" 2>/dev/null || true
            fi
            ;;
        txt|md|markdown|rst|html|htm)
            cat "$file_path" 2>/dev/null || true
            ;;
        *)
            cat "$file_path" 2>/dev/null || true
            ;;
    esac
}

collect_documentation_context() {
    log_divider "DOC CONTEXT"
    DOCUMENTATION_CONTEXT=""

    local -a doc_files=()
    while IFS= read -r -d '' doc_file; do
        doc_files+=("$doc_file")
    done < <(find "$INPUT_PATH" -maxdepth 1 -type f \
        \( -iname 'readme' -o -iname 'readme.*' -o -iname '*.md' -o -iname '*.rtf' -o -iname '*.txt' -o -iname '*.pdf' \) -print0)

    local combined=""
    local max_chars=6000
    if (( ${#doc_files[@]} )); then
        for doc_file in "${doc_files[@]}"; do
            local snippet=$(read_text_from_file "$doc_file")
            [[ -z "$snippet" ]] && continue
            combined+=$'\n['"$(basename "$doc_file")"$']\n'
            combined+="$snippet"

            if (( ${#combined} >= max_chars )); then
                combined=${combined:0:$max_chars}
                break
            fi
        done
    else
        log_info "No documentation files detected"
    fi

    local link_snippets
    link_snippets=$(jq -r '
        [ .files[]
          | select(.linkPreview != null)
          | "[Link] " + (.sourceUrl // "unknown") + "\n" + .linkPreview
        ] | join("\n")
    ' "$WORK_STATE_FILE")

    if [[ -n "$link_snippets" ]]; then
        combined+=$'\n[Link Previews]\n'
        combined+="$link_snippets"
    fi

    if [[ -z "$combined" ]]; then
        local tmp=$(mktemp)
        jq '.metadata.documentationContext = ""' "$WORK_STATE_FILE" >"$tmp"
        mv "$tmp" "$WORK_STATE_FILE"
        return
    fi

    DOCUMENTATION_CONTEXT=$(printf '%s' "$combined" | tr -d '\000' | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
    local tmp=$(mktemp)
    jq --arg doc "$DOCUMENTATION_CONTEXT" '.metadata.documentationContext = $doc' "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
    log_info "Captured documentation context (${#DOCUMENTATION_CONTEXT} chars)"
}

canonical_folder_for_extension() {
    local ext="${1:l}"
    case "$ext" in
        stl) echo "files/STLs" ;;
        obj) echo "files/OBJs" ;;
        step|stp) echo "files/STEPs" ;;
        f3d) echo "files/F3Ds" ;;
        blend) echo "files/Blenders" ;;
        scad) echo "files/SCADs" ;;
        shapr) echo "files/Shaprs" ;;
        3mf) echo "files" ;;
        gcode) echo "exports" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) echo "images" ;;
        pdf|md|txt|rtf|html|htm|doc|docx) echo "" ;;
        json|csv|yaml|yml) echo "data" ;;
        *) echo "misc" ;;
    esac
}

sanitize_folder_component() {
    local value="$1"
    value=$(normalize_readable_token "$value")
    value=$(echo "$value" | sed 's/[\/:*?"<>|]/-/g')
    value=$(echo "$value" | sed -E 's/-{2,}/-/g')
    value=$(echo "$value" | sed -E 's/ +- +/ - /g')
    value=$(echo "$value" | tr -s ' ' ' ')
    value=$(echo "$value" | sed 's/^ *//;s/ *$//')
    [[ -z "$value" ]] && value="Unsorted Project"
    echo "$value"
}

normalize_readable_token() {
    local value="$1"
    value="${value//+/ }"
    value="${value//_/ }"
    value=$(printf '%s' "$value" | sed -E 's/[^[:alnum:]-]+/ /g')
    value=$(printf '%s' "$value" | tr -s ' ')
    value=$(printf '%s' "$value" | sed -E 's/^ +//;s/ +$//')
    [[ -z "$value" ]] && value="Untitled"
    printf '%s\n' "$value"
}

normalize_filename() {
    local name="$1"
    [[ -z "$name" ]] && { printf '%s\n' "$name"; return; }

    local base="$name"
    local ext=""

    if [[ "$name" == .* ]]; then
        if [[ "$name" == *.* && "$name" != .*.* ]]; then
            ext="${name##*.}"
            base="${name%.*}"
        fi
    elif [[ "$name" == *.* ]]; then
        ext="${name##*.}"
        base="${name%.*}"
    fi

    base=$(normalize_readable_token "$base")
    if [[ -n "$ext" ]]; then
        printf '%s.%s\n' "$base" "$ext"
    else
        printf '%s\n' "$base"
    fi
}

resolve_unique_archive_destination() {
    local base_dir="$1"
    local desired_name="$2"
    local counter=1
    local candidate_path

    while :; do
        if (( counter == 1 )); then
            candidate_path="$base_dir/$desired_name"
        else
            candidate_path="$base_dir/$desired_name ($counter)"
        fi

        if [[ ! -e "$candidate_path" ]]; then
            printf '%s\n' "$candidate_path"
            return
        fi
        counter=$((counter + 1))
    done
}

get_folder_structure() {
    local base_path="$1"
    [[ -d "$base_path" ]] || return 1

    local cache_key cache_file now modified
    cache_key=$(printf '%s' "$base_path" | cksum | awk '{print $1}')
    cache_file="$CACHE_DIR/archive-structure-$cache_key.json"
    now=$(date +%s)

    if [[ -f "$cache_file" ]]; then
        modified=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        if (( now - modified < ARCHIVE_CACHE_TTL )); then
            cat "$cache_file"
            return 0
        fi
    fi

    local structure_file=$(mktemp)
    jq -n '{categories: []}' >"$structure_file"

    for category in "$base_path"/*; do
        [[ -d "$category" ]] || continue
        local category_name=$(basename "$category")
        [[ "$category_name" == _* ]] && continue

        local category_json
        category_json=$(jq -n --arg name "$category_name" --arg path "$category" '{name: $name, path: $path, subcategories: []}')

        for subfolder in "$category"/*; do
            [[ -d "$subfolder" ]] || continue
            local sub_name=$(basename "$subfolder")
            [[ "$sub_name" == _* ]] && continue
            local sub_count=$(find "$subfolder" -type f 2>/dev/null | wc -l | tr -d ' ')
            local sub_json
            sub_json=$(jq -n --arg name "$sub_name" --arg path "$subfolder" --arg count "$sub_count" '{name: $name, path: $path, itemCount: ($count|tonumber)}')
            category_json=$(jq --argjson sub "$sub_json" '.subcategories += [$sub]' <<<"$category_json")
        done

        local updated=$(mktemp)
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

invalidate_archive_cache() {
    local base_path="$1"
    local cache_key
    cache_key=$(printf '%s' "$base_path" | cksum | awk '{print $1}')
    rm -f "$CACHE_DIR/archive-structure-$cache_key.json"
}

enforce_filetype_structure() {
    log_divider "STRUCTURE ENFORCEMENT"
    log_info "Normalizing proposed folders based on file types"

    while IFS= read -r entry; do
        local id extension filename proposed_filename
        id=$(echo "$entry" | jq -r '.id')
        extension=$(echo "$entry" | jq -r '.extension // ""')
        filename=$(echo "$entry" | jq -r '.filename')
        proposed_filename=$(echo "$entry" | jq -r '.proposed.filename // empty')

        local target_folder="$(canonical_folder_for_extension "$extension")"
        local chosen_name="$filename"
        if [[ -n "$proposed_filename" ]]; then
            chosen_name="$proposed_filename"
        fi

        local normalized_name
        normalized_name=$(normalize_filename "$chosen_name")

        local relative_path
        if [[ -z "$target_folder" ]]; then
            relative_path="$normalized_name"
        else
            relative_path="$target_folder/$normalized_name"
        fi

        local absolute_path="$INPUT_PATH/$relative_path"

        local tmp=$(mktemp)
        jq --arg id "$id" \
            --arg folder "$target_folder" \
            --arg filename "$normalized_name" \
            --arg rel "$relative_path" \
            --arg abs "$absolute_path" \
            '(.files[] | select(.id == ($id|tonumber))) |= (
                .proposed.folder = (if $folder == "" then null else $folder end) |
                .proposed.filename = $filename |
                .proposed.path = $rel |
                .proposed.absolutePath = $abs
            )' "$WORK_STATE_FILE" >"$tmp"
        mv "$tmp" "$WORK_STATE_FILE"
    done < <(jq -c '.files[]' "$WORK_STATE_FILE")
}

record_agent_cycle() {
    local description="$1"
    local tmp=$(mktemp)
    jq --arg desc "$description" --arg timestamp "$(date -Iseconds)" \
        '.metadata.agentCycles += [{ description: $desc, completedAt: $timestamp }]' \
        "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

validate_agent_plan() {
    local plan_json="$1"
    local expected_ids expected_count
    expected_ids=$(jq '[.files[].id] | sort' "$WORK_STATE_FILE")
    expected_count=$(jq '.metadata.totalFiles' "$WORK_STATE_FILE")

    jq -e \
        --argjson expectedIds "$expected_ids" \
        --argjson expectedCount "$expected_count" \
        '(.files | type == "array") and
         (.files | length == $expectedCount) and
         (([.files[].id] | sort) == $expectedIds) and
         (reduce .files[] as $file (
             true;
             . and
             ($file.id | type == "number") and
             ($file.proposed | type == "object") and
             ( ($file.proposed.folder == null) or ($file.proposed.folder | type == "string") ) and
             ( ($file.proposed.filename == null) or ($file.proposed.filename | type == "string") ) and
             ( ($file.proposed.path == null) or ($file.proposed.path | type == "string") ) and
             ( ($file.proposed.absolutePath == null) or ($file.proposed.absolutePath | type == "string") ) and
             ( ($file.proposed.rationale == null) or ($file.proposed.rationale | type == "string") )
         ))' <<<"$plan_json" >/dev/null 2>&1
}

run_agentic_cycle() {
    if (( SKIP_AI )); then
        log_info "Skipping AI planning cycle by request"
        return
    fi

    log_divider "AI CYCLE"
    ensure_ai_helpers_loaded

    local system_message="You are an expert 3D printing archivist. Given JSON data describing a folder, propose polished folder structures and rename/move plans. Translate all names to clear English when they appear in other languages, normalize punctuation, and return JSON matching the schema you received, updating only metadata.agentCycles and files[].proposed.* fields."
    local state_blob=$(cat "$WORK_STATE_FILE")
    local user_message="Analyze the following JSON catalog of files. For each entry, fill the proposed fields with the desired destination folder (relative to the input root), the desired filename, and the combined path. If no change is needed, leave the proposed fields null. Respond with valid JSON only.\n\n$state_blob"

    local escaped_system escaped_user
    escaped_system=$(printf '%s' "$system_message" | jq -R -s .)
    escaped_user=$(printf '%s' "$user_message" | jq -R -s .)

    local payload
    payload=$(jq -n \
        --argjson sys "$escaped_system" \
        --argjson usr "$escaped_user" \
        '{
            messages: [
                {role: "system", content: $sys},
                {role: "user", content: $usr}
            ],
            temperature: 0.15
        }')

    debug_log_api "AGENTIC_REQUEST" "$payload"
    local response=$(get-openai-response "$payload")
    debug_log_api "AGENTIC_RESPONSE" "$response"

    if [[ -z "$response" ]]; then
        log_error "AI planning cycle returned empty response"
        exit 1
    fi

    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "AI response is not valid JSON"
        exit 1
    fi

    if ! validate_agent_plan "$response"; then
        log_error "AI response failed schema validation"
        exit 1
    fi

    printf '%s' "$response" >"$WORK_STATE_FILE"

    local tmp=$(mktemp)
    jq 'if (.metadata.duplicates? | type == "array") then . else (.metadata.duplicates = []) end' \
        "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
    record_agent_cycle "Primary planning cycle"
}

persist_state_file() {
    log_divider "STATE PERSIST"
    mkdir -p "$(dirname "$STATE_FILE")"
    cp "$WORK_STATE_FILE" "$STATE_FILE"
    log_info "State written to $STATE_FILE"
}

resolve_destination_path() {
    local proposed_path="$1"
    local proposed_folder="$2"
    local proposed_filename="$3"
    local proposed_absolute="$4"
    local current_relative="$5"
    local fallback_name="$6"

    if [[ -n "$proposed_absolute" && "$proposed_absolute" != "null" ]]; then
        echo "$proposed_absolute"
        return
    fi

    if [[ -n "$proposed_path" && "$proposed_path" != "null" ]]; then
        if [[ "$proposed_path" == /* ]]; then
            echo "$proposed_path"
        else
            echo "$INPUT_PATH/$proposed_path"
        fi
        return
    fi

    local folder_component="$proposed_folder"
    if [[ -z "$folder_component" || "$folder_component" == "null" ]]; then
        folder_component="$(dirname "$current_relative")"
    fi
    if [[ "$folder_component" == "." ]]; then
        folder_component=""
    fi

    local filename_component="$proposed_filename"
    if [[ -z "$filename_component" || "$filename_component" == "null" ]]; then
        filename_component="$fallback_name"
    fi

    if [[ -z "$folder_component" ]]; then
        echo "$INPUT_PATH/$filename_component"
    else
        echo "$INPUT_PATH/$folder_component/$filename_component"
    fi
}

files_identical() {
    local first="$1"
    local second="$2"
    [[ -f "$first" && -f "$second" ]] || return 1

    local size_a size_b
    size_a=$(stat -f%z "$first" 2>/dev/null || stat -c%s "$first" 2>/dev/null || echo 0)
    size_b=$(stat -f%z "$second" 2>/dev/null || stat -c%s "$second" 2>/dev/null || echo 0)
    [[ "$size_a" == "$size_b" ]] || return 1

    cmp -s "$first" "$second"
}

record_duplicate_detection() {
    local file_id="$1"
    local original="$2"
    local existing="$3"

    local tmp=$(mktemp)
    jq --arg id "$file_id" --arg orig "$original" --arg dup "$existing" \
        '.metadata.duplicates += [{ fileId: ($id|tonumber), originalPath: $orig, duplicateOf: $dup }]' \
        "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

apply_rename_plan() {
    log_divider "APPLY"
    if (( DRY_RUN )); then
        log_info "Dry-run enabled; skipping filesystem changes"
        return
    fi

    log_info "Applying rename/move plan"
    local applied=0
    while IFS=$'\t' read -r file_id original_path proposed_path proposed_folder proposed_filename proposed_absolute; do
        [[ -z "$original_path" || "$original_path" == "null" ]] && continue
        if [[ ! -e "$original_path" ]]; then
            log_warn "Original file missing, skipping: $original_path"
            continue
        fi

        local relative_path="${original_path#$INPUT_PATH/}"
        local fallback_name="$(basename "$original_path")"
        local destination
        destination=$(resolve_destination_path "$proposed_path" "$proposed_folder" "$proposed_filename" "$proposed_absolute" "$relative_path" "$fallback_name")

        if [[ -z "$destination" ]]; then
            log_warn "No destination resolved for $original_path; skipping"
            continue
        fi
        if [[ "$original_path" == "$destination" ]]; then
            continue
        fi

        if [[ -e "$destination" ]] && files_identical "$original_path" "$destination"; then
            log_info "Duplicate detected; skipping move for $original_path (matches $destination)"
            record_duplicate_detection "$file_id" "$original_path" "$destination"
            continue
        fi

        local destination_dir="$(dirname "$destination")"
        mkdir -p "$destination_dir"

        local final_destination="$destination"
        local attempt=1
        while [[ -e "$final_destination" ]]; do
            local base="$(basename "$destination")"
            local ext=""
            if [[ "$base" == *.* ]]; then
                ext=".${base##*.}"
                base="${base%.*}"
            fi
            final_destination="$destination_dir/${base}_agentic${attempt}${ext}"
            attempt=$((attempt + 1))
        done

        mv "$original_path" "$final_destination"
        applied=$((applied + 1))

        local tmp=$(mktemp)
        jq --arg id "$file_id" --arg path "$final_destination" \
            '(.files[] | select((.id|tostring) == $id)) |= (.appliedPath = $path)' \
            "$STATE_FILE" >"$tmp"
        mv "$tmp" "$STATE_FILE"
        log_info "Moved $(basename "$original_path") -> $final_destination"
    done < <(jq -r '.files[] | [(.id|tostring), .originalPath, (.proposed.path // ""), (.proposed.folder // ""), (.proposed.filename // ""), (.proposed.absolutePath // "")] | @tsv' "$STATE_FILE")

    log_info "Applied $applied rename operations"
}

plan_archive_destination() {
    log_divider "ARCHIVE PLANNING"

    local archive_category archive_subcategory archive_folder
    local rationale=""
    local folder_structure_json
    if folder_structure_json=$(get_folder_structure "$BASE_PATH" 2>/dev/null); then
        :
    else
        folder_structure_json='{"categories": []}'
    fi

    local summary_json
    summary_json=$(jq '{folderName: .metadata.folderName, totalFiles: .metadata.totalFiles, documentationContext: (.metadata.documentationContext // ""), files: [ .files[] | {filename, extension, category} ]}' "$STATE_FILE")

    if (( SKIP_AI )); then
        log_info "AI disabled; using default archive destination"
        archive_category="Unsorted"
        archive_subcategory="Needs Review"
        archive_folder=$(jq -r '.metadata.folderName' "$STATE_FILE")
        rationale="AI planning skipped by user request"
    else
        ensure_ai_helpers_loaded

        local system_message="You curate a hierarchical 3D print archive organized as Category/Subcategory/ProjectFolder. Prefer reusing existing categories whenever possible; add new subcategories more often than new categories, and only create a brand-new category when no existing theme fits. Translate non-English names to clear English, normalize punctuation, and always output strict JSON with keys parentCategory, subCategory, folderName, rationale."

        local user_message
        printf -v user_message 'Archive structure JSON:\n%s\n\nFolder summary JSON:\n%s\n\nInstructions:\n1. Favor existing categories when possible.\n2. Prefer introducing a new subcategory within an existing category before inventing an entirely new category.\n3. Only create a brand-new category if filenames and documentation clearly describe a novel theme.\n4. Respond only with JSON.\n' "$folder_structure_json" "$summary_json"

        local escaped_system escaped_user payload response
        escaped_system=$(printf '%s' "$system_message" | jq -R -s .)
        escaped_user=$(printf '%s' "$user_message" | jq -R -s .)

        payload=$(jq -n \
            --argjson sys "$escaped_system" \
            --argjson usr "$escaped_user" \
            '{
                messages: [
                    {role: "system", content: $sys},
                    {role: "user", content: $usr}
                ],
                temperature: 0.1
            }')

        debug_log_api "ARCHIVE_PLAN_REQUEST" "$payload"
        response=$(get-openai-response "$payload")
        debug_log_api "ARCHIVE_PLAN_RESPONSE" "$response"

        if [[ -n "$response" ]] && echo "$response" | jq . >/dev/null 2>&1; then
            archive_category=$(echo "$response" | jq -r '.parentCategory // empty')
            archive_subcategory=$(echo "$response" | jq -r '.subCategory // empty')
            archive_folder=$(echo "$response" | jq -r '.folderName // empty')
            rationale=$(echo "$response" | jq -r '.rationale // empty')
        else
            log_warn "Archive planning AI response invalid; falling back to defaults"
        fi

        local default_folder_name
        default_folder_name=$(jq -r '.metadata.folderName' "$STATE_FILE")

        [[ -z "$archive_category" ]] && archive_category="Unsorted"
        [[ -z "$archive_subcategory" ]] && archive_subcategory="Needs Review"
        [[ -z "$archive_folder" ]] && archive_folder="$default_folder_name"
        [[ -z "$rationale" ]] && rationale="AI response missing rationale; used defaults where necessary"
    fi

    archive_category=$(sanitize_folder_component "$archive_category")
    archive_subcategory=$(sanitize_folder_component "$archive_subcategory")
    archive_folder=$(sanitize_folder_component "$archive_folder")

    local tmp=$(mktemp)
    jq --arg category "$archive_category" \
       --arg sub "$archive_subcategory" \
       --arg folder "$archive_folder" \
       --arg base "$BASE_PATH" \
       --arg rationale "$rationale" \
        '.metadata.archivePlan = {
            category: $category,
            subcategory: $sub,
            folderName: $folder,
            basePath: $base,
            rationale: (if $rationale == "" then null else $rationale end)
        }' "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

apply_archive_destination() {
    log_divider "ARCHIVE MOVE"

    local archive_category archive_subcategory archive_folder
    archive_category=$(jq -r '.metadata.archivePlan.category // "Unsorted"' "$STATE_FILE")
    archive_subcategory=$(jq -r '.metadata.archivePlan.subcategory // "Needs Review"' "$STATE_FILE")
    archive_folder=$(jq -r '.metadata.archivePlan.folderName // .metadata.folderName' "$STATE_FILE")

    archive_category=$(sanitize_folder_component "$archive_category")
    archive_subcategory=$(sanitize_folder_component "$archive_subcategory")
    archive_folder=$(sanitize_folder_component "$archive_folder")

    local category_dir="$BASE_PATH/$archive_category"
    local target_dir="$category_dir/$archive_subcategory"
    local resolved_destination

    if (( DRY_RUN )); then
        resolved_destination=$(resolve_unique_archive_destination "$target_dir" "$archive_folder")
        log_info "Dry-run: folder would be moved to $resolved_destination"
        local tmp=$(mktemp)
        jq --arg path "$resolved_destination" '.metadata.archivePlan.destinationPath = $path' "$STATE_FILE" >"$tmp"
        mv "$tmp" "$STATE_FILE"
        return
    fi

    mkdir -p "$target_dir"
    resolved_destination=$(resolve_unique_archive_destination "$target_dir" "$archive_folder")

    log_info "Moving organized folder to archive: $resolved_destination"
    mv "$INPUT_PATH" "$resolved_destination"
    invalidate_archive_cache "$BASE_PATH"

    local updated_backup_path=""
    if [[ -n "$BACKUP_ARCHIVE" ]]; then
        updated_backup_path="$resolved_destination/$(basename "$BACKUP_ARCHIVE")"
        BACKUP_ARCHIVE="$updated_backup_path"
    fi

    INPUT_PATH="$resolved_destination"
    STATE_FILE="$resolved_destination/$DEFAULT_STATE_FILENAME"

    local tmp=$(mktemp)
    jq --arg dest "$resolved_destination" --arg backup "$updated_backup_path" '
        .metadata.inputPath = $dest |
        .metadata.archivePlan.destinationPath = $dest |
        (if $backup == "" then . else (.metadata.backupZip = $backup) end)
    ' "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

reveal_result_folder() {
    local target_path context
    if (( DRY_RUN )); then
        target_path="$ORIGINAL_INPUT_PATH"
        context="original folder (dry-run)"
    else
        target_path="$INPUT_PATH"
        context="final folder"
    fi

    if [[ -z "$target_path" || ! -d "$target_path" ]]; then
        log_warn "Cannot open $context; directory missing: $target_path"
        return
    fi

    log_divider "REVEAL"
    log_info "Opening $context: $target_path"

    if command -v open >/dev/null 2>&1; then
        open "$target_path" >/dev/null 2>&1 || log_warn "'open' command failed for $target_path"
        return
    fi

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$target_path" >/dev/null 2>&1 || log_warn "'xdg-open' command failed for $target_path"
        return
    fi

    log_warn "No supported folder opener available (tried 'open' and 'xdg-open')"
}

cleanup() {
    [[ -n "$WORK_STATE_FILE" && -f "$WORK_STATE_FILE" && "$WORK_STATE_FILE" != "$STATE_FILE" ]] && rm -f "$WORK_STATE_FILE"
    [[ -n "$FILE_ENTRIES_BUFFER" && -f "$FILE_ENTRIES_BUFFER" ]] && rm -f "$FILE_ENTRIES_BUFFER"
}

main() {
    parse_args "$@"
    setup_logging
    validate_environment
    trap cleanup EXIT

    create_backup_archive
    initialize_state_document
    build_file_inventory
    collect_documentation_context
    run_agentic_cycle
    if (( SKIP_AI )); then
        log_info "Skipping structure enforcement due to --skip-ai"
    else
        enforce_filetype_structure
    fi
    persist_state_file
    if (( SKIP_AI )); then
        log_info "Skipping rename/move application due to --skip-ai"
    else
        apply_rename_plan
    fi
    plan_archive_destination
    apply_archive_destination
    reveal_result_folder
}

main "$@"
