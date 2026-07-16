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
source "$SCRIPT_DIR/3d-print-catalog-functions.sh"
DEFAULT_STATE_FILENAME="agentic-plan.json"
SUMMARY_FILENAME="SUMMARY.md"
readonly BASE_PATH="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
readonly RECOVERY_ROOT="${ORGANIZE_3D_RECOVERY_DIR:-$BASE_PATH/_recovery}"
readonly AI_PROMPT_VERSION="3d-import-v3"
DRY_RUN=0
SKIP_AI=0
SKIP_BACKUP=0
STATE_FILE=""
STATE_FILE_PROVIDED=0
STATE_FILE_EPHEMERAL=0
INPUT_PATH=""
WORK_STATE_FILE=""
BACKUP_ARCHIVE=""
ORIGINAL_INPUT_PATH=""
FILE_INDEX=0
AI_HELPERS_LOADED=0
DOCUMENTATION_CONTEXT=""
FILE_ENTRIES_BUFFER=""
IMPORT_ID=""
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/organize-3d-imports"
ARCHIVE_CACHE_TTL=${ARCHIVE_CACHE_TTL:-900}
typeset -A WEBLOC_URL_REGISTRY=()
typeset -A CONTENT_HASH_REGISTRY=()


typeset -a IGNORE_PATTERNS=(
    '.DS_Store'
    '._*'
    'Thumbs.db'
    'desktop.ini'
    "$DEFAULT_STATE_FILENAME"
    "$SUMMARY_FILENAME"
    '*_backup_*.zip'
    '.3d-print-catalog*'
)

usage() {
    cat <<'USAGE'
Usage: organize-3d-imports.sh [options] <folder>

Options:
  --state-file <path>   Write the JSON state file to this path (default: <folder>/agentic-plan.json)
  --dry-run             Perform analysis and persist state without renaming files
  --skip-ai             Skip the AI planning cycle (state will contain only discovery data)
  --skip-backup         Skip the recovery archive (intended for read-only backfills/tests)
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
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state-file)
                [[ $# -lt 2 ]] && { echo "--state-file requires a value" >&2; exit 1; }
                STATE_FILE="$2"
                STATE_FILE_PROVIDED=1
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
            --skip-backup)
                SKIP_BACKUP=1
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
    IMPORT_ID="${ORGANIZE_3D_JOB_ID:-$(date +"%Y%m%dT%H%M%S")-$$}"

    require_command jq
    require_command zip
    require_command unzip
    require_command find
    require_command stat
    require_command cmp
    require_command shasum
    require_command sort
    require_command sqlite3
    require_command base64
    require_command curl
    require_command xmllint

    if [[ -z "$STATE_FILE" ]]; then
        STATE_FILE="$INPUT_PATH/$DEFAULT_STATE_FILENAME"
    fi

    mkdir -p "$BASE_PATH"
    mkdir -p "$CACHE_DIR"
    if (( ! DRY_RUN )) && (( ! SKIP_BACKUP )); then
        mkdir -p "$RECOVERY_ROOT/$IMPORT_ID"
    fi
    WORK_STATE_FILE=$(mktemp -t agentic-state.XXXXXX.json)
    FILE_ENTRIES_BUFFER=$(mktemp -t agentic-files.XXXXXX.json)

    if (( DRY_RUN )) && (( ! STATE_FILE_PROVIDED )); then
        STATE_FILE="$WORK_STATE_FILE"
        STATE_FILE_EPHEMERAL=1
        log_info "Dry-run: agentic plan will stay in a temporary file (use --state-file to override)"
    fi
}

create_backup_archive() {
    log_divider "BACKUP"
    if (( DRY_RUN )) || (( SKIP_BACKUP )); then
        log_info "Recovery archive skipped"
        BACKUP_ARCHIVE=""
        return
    fi

    log_info "Creating external recovery archive before analysis"

    local folder_name parent_dir
    folder_name="$(basename "$INPUT_PATH")"
    parent_dir="$(dirname "$INPUT_PATH")"
    BACKUP_ARCHIVE="$RECOVERY_ROOT/$IMPORT_ID/source.zip"

    if (cd "$parent_dir" && command zip -qr "$BACKUP_ARCHIVE" "$folder_name" \
        -x "*/$DEFAULT_STATE_FILENAME" "*/$SUMMARY_FILENAME" "*/*_backup_*.zip" \
        "*/.3d-print-catalog*" "*/.DS_Store" "*/._*"); then
        log_info "Backup created at $BACKUP_ARCHIVE"
        return
    fi

    log_error "Failed to create recovery archive"
    return 1
}

initialize_state_document() {
    log_divider "STATE INIT"
    local generated_at folder_name provider model recovery_json
    generated_at=$(date -Iseconds)
    folder_name="$(basename "$INPUT_PATH")"
    provider="${AI_PROVIDER:-openai}"
    if [[ "$provider" == "copilot" ]]; then
        model="${COPILOT_MODEL:-gpt-5.4}"
    else
        model="${OPENAI_MODEL:-gpt-5.4}"
    fi
    recovery_json="null"
    if [[ -n "$BACKUP_ARCHIVE" ]]; then
        recovery_json=$(jq -n --arg id "$IMPORT_ID" --arg archive "source.zip" \
            '{id: $id, archiveName: $archive}')
    fi

    jq -n \
        --arg schema "2.0" \
        --arg import_id "$IMPORT_ID" \
        --arg generated "$generated_at" \
        --arg folder "$folder_name" \
        --arg dry "$DRY_RUN" \
        --arg provider "$provider" \
        --arg model "$model" \
        --arg prompt_version "$AI_PROMPT_VERSION" \
        --argjson recovery "$recovery_json" \
        '{
            metadata: {
                schemaVersion: $schema,
                importId: $import_id,
                generatedAt: $generated,
                folderName: $folder,
                recovery: $recovery,
                dryRun: ($dry == "1"),
                ai: {
                    provider: $provider,
                    model: $model,
                    promptVersion: $prompt_version
                },
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
        stl|obj|3mf|amf|ply|glb|gltf|dae|3ds|wrl|vrml|x3d) echo "3d-model" ;;
        step|stp|iges|igs|brep|sat|x_t|x_b|f3d|f3z|sldprt|sldasm|ipt|iam|catpart|catproduct|fcstd|blend|scad|shapr|skp|dwg|dxf) echo "3d-model" ;;
        gcode|bgcode|gx|x3g|ufp|nc) echo "print-export" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff|svg) echo "image" ;;
        pdf|md|txt|rtf|html|htm|doc|docx|odt|pages|webloc|url) echo "documentation" ;;
        json|csv|yaml|yml) echo "data" ;;
        zip|7z|rar|tar|gz|bz2|xz) echo "archive" ;;
        *) echo "other" ;;
    esac
}

append_file_entry() {
    local file_path="$1"
    local rel_path="${file_path#$INPUT_PATH/}"
    local filename
    filename="$(basename "$file_path")"
    local extension=""
    if [[ "$filename" == *.* ]]; then
        extension="${filename##*.}"
    fi
    local size_bytes
    size_bytes=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
    local category sha256 content_duplicate_of
    category=$(classify_extension "$extension")
    sha256=$(command shasum -a 256 "$file_path" | command awk '{print $1}')
    content_duplicate_of=""
    if [[ -n "${CONTENT_HASH_REGISTRY[$sha256]-}" ]]; then
        content_duplicate_of="${CONTENT_HASH_REGISTRY[$sha256]}"
    else
        CONTENT_HASH_REGISTRY[$sha256]="$rel_path"
    fi
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
                WEBLOC_URL_REGISTRY[$source_url]="$rel_path"
            fi
        fi
    fi

    local file_json
    file_json=$(jq -n \
        --arg id "$file_id" \
        --arg relative "$rel_path" \
        --arg name "$filename" \
        --arg ext "${extension:l}" \
        --arg size "$size_bytes" \
        --arg sha256 "$sha256" \
        --arg category "$category" \
        --arg source "$source_url" \
        --arg preview "$link_preview" \
        --arg duplicate "$url_duplicate_of" \
        --arg content_duplicate "$content_duplicate_of" \
        '{
            id: ($id|tonumber),
            relativePath: $relative,
            filename: $name,
            extension: $ext,
            sizeBytes: ($size|tonumber),
            sha256: $sha256,
            category: $category,
            sourceUrl: (if $source == "" then null else $source end),
            linkPreview: (if $preview == "" then null else $preview end),
            urlDuplicateOf: (if $duplicate == "" then null else $duplicate end),
            contentDuplicateOf: (if $content_duplicate == "" then null else $content_duplicate end),
            proposed: {
                folder: null,
                filename: null,
                path: null,
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
    record_content_duplicates
}

record_url_duplicates() {
    local tmp=$(mktemp)
    jq '
        .metadata.duplicates += (
            [ .files[]
              | select(.urlDuplicateOf != null)
              | {
                    fileId: .id,
                    relativePath: .relativePath,
                    duplicateOf: .urlDuplicateOf,
                    url: .sourceUrl,
                    type: "url"
                }
            ]
        )
    ' "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

record_content_duplicates() {
    local tmp=$(mktemp)
    jq '
        .metadata.duplicates += (
            [ .files[]
              | select(.contentDuplicateOf != null)
              | {
                    fileId: .id,
                    relativePath: .relativePath,
                    duplicateOf: .contentDuplicateOf,
                    sha256: .sha256,
                    type: "content"
                }
            ]
        )
    ' "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

annotate_archive_catalog_matches() {
    log_divider "CATALOG COMPARISON"
    if annotate_3d_catalog_matches "$WORK_STATE_FILE"; then
        local matched_files duplicates versions exact_project
        matched_files=$(command jq -r '.metadata.catalog.matchedFiles // 0' "$WORK_STATE_FILE")
        duplicates=$(command jq -r '.metadata.catalog.duplicateMatches // 0' "$WORK_STATE_FILE")
        versions=$(command jq -r '.metadata.catalog.versionMatches // 0' "$WORK_STATE_FILE")
        exact_project=$(command jq -r '.metadata.catalog.exactDuplicateProject.relativePath // empty' "$WORK_STATE_FILE")
        log_info "Catalog matches: $matched_files files ($duplicates duplicate, $versions version)"
        [[ -n "$exact_project" ]] && log_warn "Exact archived project match: $exact_project"
        return 0
    fi
    log_warn "Catalog comparison failed; import will continue and backfill can repair the catalog"
    return 0
}

build_file_inventory() {
    log_divider "DISCOVERY"
    log_info "Scanning directory tree for files"

    : >"$FILE_ENTRIES_BUFFER"
    FILE_INDEX=0
    WEBLOC_URL_REGISTRY=()
    CONTENT_HASH_REGISTRY=()
    local found_any=0
    local file base skip pattern
    while IFS= read -r -d '' file; do
        base="$(basename "$file")"
        skip=0
        for pattern in "${IGNORE_PATTERNS[@]}"; do
            if [[ "$base" == $~pattern ]]; then
                skip=1
                break
            fi
        done
        (( skip )) && continue

        append_file_entry "$file"
        found_any=1
    done < <(find "$INPUT_PATH" -type f -print0 | LC_ALL=C command sort -z)

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
        \( -iname 'readme' -o -iname 'readme.*' -o -iname '*.md' -o -iname '*.rtf' -o -iname '*.txt' -o -iname '*.pdf' \) \
        ! -name "$SUMMARY_FILENAME" ! -name "$DEFAULT_STATE_FILENAME" -print0)

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
        amf|ply|glb|gltf|dae|3ds|wrl|vrml|x3d) echo "files/Meshes" ;;
        iges|igs) echo "files/IGES" ;;
        f3z) echo "files/F3Ds" ;;
        sldprt|sldasm) echo "files/SOLIDWORKS" ;;
        ipt|iam) echo "files/Autodesk Inventor" ;;
        catpart|catproduct) echo "files/CATIA" ;;
        fcstd) echo "files/FreeCAD" ;;
        skp) echo "files/SketchUp" ;;
        brep|sat|x_t|x_b|dwg|dxf) echo "files/CAD" ;;
        gcode|bgcode|gx|x3g|ufp|nc) echo "exports" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff|svg) echo "images" ;;
        pdf|md|txt|rtf|html|htm|doc|docx|odt|pages|webloc|url) echo "" ;;
        json|csv|yaml|yml) echo "data" ;;
        zip|7z|rar|tar|gz|bz2|xz) echo "source" ;;
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
    [[ -z "$value" || "$value" == "." || "$value" == ".." ]] && value="Unsorted Project"
    echo "$value"
}

sanitize_existing_folder_component() {
    local value="$1"
    value=$(printf '%s' "$value" | tr '\r\n\t' '   ')
    value=$(printf '%s' "$value" | sed 's#[/:*?"<>|]#-#g')
    value=$(printf '%s' "$value" | sed -E 's/-{2,}/-/g; s/^ +//; s/ +$//')
    [[ -z "$value" || "$value" == "." || "$value" == ".." ]] && value="Unsorted Project"
    printf '%s\n' "$value"
}

taxonomy_alias_key() {
    local value="${1:l}"
    value="${value//&/ and }"
    value=$(printf '%s' "$value" | sed -E 's/[^[:alnum:]]+//g')
    printf '%s\n' "$value"
}

canonical_category_alias() {
    local value="$1"
    local key
    key=$(taxonomy_alias_key "$value")
    case "$key" in
        artsandcrafts|artscrafts) printf '%s\n' "Arts and Crafts" ;;
        computerandgameconsoleparts|computersandgameconsoleparts) printf '%s\n' "Computer and Game Console Parts" ;;
        printerscuttersandmediamachinespartsandtools) printf '%s\n' "Printers, Cutters, and Media Machines Parts and Tools" ;;
        rccarsandcyberbrick) printf '%s\n' "RC Cars and CyberBrick" ;;
        sportsandrecreation) printf '%s\n' "Sports and Recreation" ;;
        toysgamesandcharacters|toysandgamesandcharacters) printf '%s\n' "Toys, Games, and Characters" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

canonicalize_archive_category() {
    local candidate="$1"
    local structure_json="$2"
    local preferred candidate_key existing existing_canonical exact
    local -a existing_names
    preferred=$(canonical_category_alias "$candidate")
    exact=$(command jq -r --arg preferred "$preferred" \
        '[.categories[].name | select(. == $preferred)][0] // empty' <<<"$structure_json")
    if [[ -n "$exact" ]]; then
        printf '%s\n' "$exact"
        return
    fi

    candidate_key=$(taxonomy_alias_key "$preferred")
    existing_names=("${(@f)$(command jq -r '.categories[].name' <<<"$structure_json")}")
    for existing in "${existing_names[@]}"; do
        existing_canonical=$(canonical_category_alias "$existing")
        if [[ "$existing_canonical" == "$preferred" ||
            "$(taxonomy_alias_key "$existing_canonical")" == "$candidate_key" ]]; then
            printf '%s\n' "$existing"
            return
        fi
    done
    sanitize_folder_component "$preferred"
}

canonicalize_archive_subcategory() {
    local candidate="$1"
    local category="$2"
    local structure_json="$3"
    local candidate_key existing
    local -a existing_names
    candidate_key=$(taxonomy_alias_key "$candidate")
    existing_names=("${(@f)$(command jq -r --arg category "$category" \
        '.categories[] | select(.name == $category) | .subcategories[].name' <<<"$structure_json")}")
    for existing in "${existing_names[@]}"; do
        if [[ "$(taxonomy_alias_key "$existing")" == "$candidate_key" ]]; then
            printf '%s\n' "$existing"
            return
        fi
    done
    sanitize_folder_component "$candidate"
}

normalize_readable_token() {
    local value="$1"
    value="${value//+/ }"
    value="${value//_/ }"
    value=$(printf '%s' "$value" | sed -E 's/[^[:alnum:].-]+/ /g')
    value=$(printf '%s' "$value" | tr -s ' ')
    value=$(printf '%s' "$value" | sed -E 's/^ +//;s/ +$//')
    [[ -z "$value" ]] && value="Untitled"
    value=$(title_case_string "$value")
    printf '%s\n' "$value"
}

normalize_word_piece() {
    local piece="$1"
    local lower_piece="${piece:l}"
    case "$lower_piece" in
        ipad) printf '%s' "iPad"; return ;;
        iphone) printf '%s' "iPhone"; return ;;
        imac) printf '%s' "iMac"; return ;;
        ios) printf '%s' "iOS"; return ;;
        macos) printf '%s' "macOS"; return ;;
        makerworld) printf '%s' "MakerWorld"; return ;;
        bambulab) printf '%s' "Bambu Lab"; return ;;
        bambustudio) printf '%s' "Bambu Studio"; return ;;
        orcaslicer) printf '%s' "OrcaSlicer"; return ;;
        prusaslicer) printf '%s' "PrusaSlicer"; return ;;
        myminifactory) printf '%s' "MyMiniFactory"; return ;;
        openscad) printf '%s' "OpenSCAD"; return ;;
        shapr3d) printf '%s' "Shapr3D"; return ;;
        freecad) printf '%s' "FreeCAD"; return ;;
        onshape) printf '%s' "Onshape"; return ;;
        solidworks) printf '%s' "SOLIDWORKS"; return ;;
        sketchup) printf '%s' "SketchUp"; return ;;
        thingiverse) printf '%s' "Thingiverse"; return ;;
        printables) printf '%s' "Printables"; return ;;
        gridfinity) printf '%s' "Gridfinity"; return ;;
        gopro) printf '%s' "GoPro"; return ;;
        youtube) printf '%s' "YouTube"; return ;;
        cyberbrick) printf '%s' "CyberBrick"; return ;;
        nfc|qr|rfid|usb|hdmi|led|rgb|tpu|pla|petg|abs|asa|cad|cnc|rc|vr|ar|gps|stl|obj|step|iges|3mf)
            printf '%s' "${lower_piece:u}"
            return
            ;;
    esac

    if [[ "$lower_piece" == <->(|.<->)mah ]]; then
        printf '%smAh' "${lower_piece%mah}"
        return
    fi
    if [[ "$lower_piece" == <->(|.<->)ma ]]; then
        printf '%smA' "${lower_piece%ma}"
        return
    fi
    if [[ "$lower_piece" == <->(|.<->)ah ]]; then
        printf '%sAh' "${lower_piece%ah}"
        return
    fi
    if [[ "$lower_piece" == <->(|.<->)(v|w|a) ]]; then
        printf '%s%s' "${lower_piece[1,-2]}" "${lower_piece[-1]:u}"
        return
    fi
    if [[ "$lower_piece" == <->(|.<->)(mm|cm|in|ft|g|kg|oz|lb|ml) ]]; then
        printf '%s' "$lower_piece"
        return
    fi
    if [[ "$piece" == "${piece:u}" && "$piece" != "${piece:l}" ]]; then
        printf '%s' "$piece"
        return
    fi
    if [[ "$piece" == [[:lower:]]* && "$piece" == *[[:upper:]]* ]]; then
        printf '%s' "$piece"
        return
    fi
    local interior="${piece[2,-1]-}"
    if [[ "$piece" == [[:upper:]]* && "$piece" == *[[:lower:]]* && "$interior" == *[[:upper:]]* ]]; then
        printf '%s' "$piece"
        return
    fi
    local first_char="${lower_piece%${lower_piece#?}}"
    local rest="${lower_piece#?}"
    printf '%s' "${first_char:u}${rest}"
}

title_case_word() {
    local token="$1"
    [[ -z "$token" ]] && { printf '%s' "$token"; return; }

    local saved_ifs="$IFS"
    IFS='-'
    local -a pieces
    read -r -A pieces <<< "$token"
    IFS="$saved_ifs"

    if (( ${#pieces[@]} == 0 )); then
        printf '%s' "$token"
        return
    fi

    local -a processed=()
    local piece
    for piece in "${pieces[@]}"; do
        if [[ -z "$piece" ]]; then
            processed+=("$piece")
            continue
        fi
        processed+=("$(normalize_word_piece "$piece")")
    done

    printf '%s' "${(j:-:)processed}"
}

title_case_string() {
    local value="$1"
    [[ -z "$value" ]] && { printf '%s\n' "$value"; return; }

    local saved_ifs="$IFS"
    IFS=$' \t\n'
    local -a words
    read -r -A words <<< "$value"
    IFS="$saved_ifs"

    if (( ${#words[@]} == 0 )); then
        printf '%s\n' "$value"
        return
    fi

    local -a processed_words=()
    local word
    for word in "${words[@]}"; do
        processed_words+=("$(title_case_word "$word")")
    done

    printf '%s\n' "${(j: :)processed_words}"
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
        printf '%s.%s\n' "$base" "${ext:l}"
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

is_safe_archive_destination() {
    local candidate="$1"
    local root="${BASE_PATH:A}"
    local resolved="${candidate:A}"
    [[ "$resolved" == "$root"/* ]]
}

directory_hash_inventory_matches_state() {
    local directory="$1"
    local state_file="$2"
    local expected_hashes actual_hashes unsorted_hashes
    expected_hashes=$(command mktemp -t 3d-expected-hashes.XXXXXX)
    actual_hashes=$(command mktemp -t 3d-actual-hashes.XXXXXX)
    unsorted_hashes=$(command mktemp -t 3d-unsorted-hashes.XXXXXX)

    if ! command jq -r '.files[].sha256' "$state_file" | LC_ALL=C command sort >"$expected_hashes"; then
        command rm -f "$expected_hashes" "$actual_hashes" "$unsorted_hashes"
        return 1
    fi

    local file base skip pattern sha256
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
        if ! sha256=$(command shasum -a 256 "$file" | command awk '{print $1}'); then
            command rm -f "$expected_hashes" "$actual_hashes" "$unsorted_hashes"
            return 1
        fi
        print -r -- "$sha256" >>"$unsorted_hashes"
    done < <(command find "$directory" -type f -print0 | LC_ALL=C command sort -z)

    if ! LC_ALL=C command sort "$unsorted_hashes" >"$actual_hashes"; then
        command rm -f "$expected_hashes" "$actual_hashes" "$unsorted_hashes"
        return 1
    fi
    if command cmp -s "$expected_hashes" "$actual_hashes"; then
        command rm -f "$expected_hashes" "$actual_hashes" "$unsorted_hashes"
        return 0
    fi
    command rm -f "$expected_hashes" "$actual_hashes" "$unsorted_hashes"
    return 1
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
        category_json=$(jq -n --arg name "$category_name" '{name: $name, subcategories: []}')

        for subfolder in "$category"/*; do
            [[ -d "$subfolder" ]] || continue
            local sub_name=$(basename "$subfolder")
            [[ "$sub_name" == _* ]] && continue
            local sub_count=$(find "$subfolder" -type f 2>/dev/null | wc -l | tr -d ' ')
            local sub_json
            sub_json=$(jq -n --arg name "$sub_name" --arg count "$sub_count" '{name: $name, itemCount: ($count|tonumber)}')
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

    local entry id extension filename proposed_filename target_folder chosen_name
    local normalized_name relative_path tmp
    while IFS= read -r entry; do
        id=$(echo "$entry" | jq -r '.id')
        extension=$(echo "$entry" | jq -r '.extension // ""')
        filename=$(echo "$entry" | jq -r '.filename')
        proposed_filename=$(echo "$entry" | jq -r '.proposed.filename // empty')

        target_folder="$(canonical_folder_for_extension "$extension")"
        chosen_name="$filename"
        if [[ -n "$proposed_filename" ]]; then
            chosen_name="$proposed_filename"
        fi

        normalized_name=$(normalize_filename "$chosen_name")

        if [[ -z "$target_folder" ]]; then
            relative_path="$normalized_name"
        else
            relative_path="$target_folder/$normalized_name"
        fi

        tmp=$(mktemp)
        jq --arg id "$id" \
            --arg folder "$target_folder" \
            --arg filename "$normalized_name" \
            --arg rel "$relative_path" \
            '(.files[] | select(.id == ($id|tonumber))) |= (
                .proposed.folder = (if $folder == "" then null else $folder end) |
                .proposed.filename = $filename |
                .proposed.path = $rel
            )' "$WORK_STATE_FILE" >"$tmp"
        mv "$tmp" "$WORK_STATE_FILE"
    done < <(jq -c '.files[]' "$WORK_STATE_FILE")
}

ensure_agent_cycle_timestamps() {
    local target_file="$1"
    local fallback="${2:-$(date -Iseconds)}"
    local tmp=$(mktemp)
    jq --arg fallback "$fallback" '
        . as $doc
        | .metadata.agentCycles = (
            (if ($doc.metadata.agentCycles? | type) == "array" then $doc.metadata.agentCycles else [] end)
            | map(
                if (type == "object") then
                    if ((.completedAt // "") | length) == 0 then
                        . + { completedAt: ($doc.metadata.generatedAt // $fallback) }
                    else
                        .
                    end
                else
                    { description: (.|tostring), completedAt: ($doc.metadata.generatedAt // $fallback) }
                end
            )
        )
    ' "$target_file" >"$tmp"
    mv "$tmp" "$target_file"
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
        '((keys | sort) == ["files"]) and
         (.files | type == "array") and
         (.files | length == $expectedCount) and
         (([.files[].id] | sort) == $expectedIds) and
         (reduce .files[] as $file (
            true;
            . and
            (($file | keys | sort) == ["id", "proposed"]) and
            ($file.id | type == "number") and
            ($file.proposed | type == "object") and
            (($file.proposed | keys | sort) == ["filename", "folder", "path", "rationale"]) and
            ( ($file.proposed.folder == null) or ($file.proposed.folder | type == "string") ) and
            ( ($file.proposed.filename == null) or ($file.proposed.filename | type == "string") ) and
            ( ($file.proposed.path == null) or ($file.proposed.path | type == "string") ) and
            ( ($file.proposed.rationale == null) or ($file.proposed.rationale | type == "string") ) and
            (
                ($file.proposed.path == null) or
                (
                    ($file.proposed.path | startswith("/") | not) and
                    ([$file.proposed.path | split("/")[] | select(. == "" or . == "." or . == "..")] | length == 0)
                )
            ) and
            (
                ($file.proposed.folder == null) or
                (
                    ($file.proposed.folder | startswith("/") | not) and
                    ([$file.proposed.folder | split("/")[] | select(. == "" or . == "." or . == "..")] | length == 0)
                )
            ) and
            (
                ($file.proposed.filename == null) or
                (
                    ($file.proposed.filename | contains("/") | not) and
                    ($file.proposed.filename != ".") and
                    ($file.proposed.filename != "..")
                )
            )
         ))' <<<"$plan_json" >/dev/null 2>&1
}

merge_agent_plan() {
    local plan_json="$1"
    local tmp
    tmp=$(mktemp)
    jq --argjson plan "$plan_json" '
        .files |= map(
           . as $local
           | ($plan.files[] | select(.id == $local.id)) as $suggestion
           | .proposed = $suggestion.proposed
        )
    ' "$WORK_STATE_FILE" >"$tmp"
    mv "$tmp" "$WORK_STATE_FILE"
}

run_agentic_cycle() {
    if (( SKIP_AI )); then
        log_info "Skipping AI planning cycle by request"
        return
    fi

    log_divider "AI CYCLE"
    ensure_ai_helpers_loaded

    local system_message="You are an expert 3D printing archivist. Return only rename and relative-folder suggestions keyed by the supplied immutable file IDs. Never emit absolute paths or parent-directory traversal. Translate non-English names to clear English and normalize punctuation while preserving established brand capitalization, technical acronyms, dimensions, and units."
    local state_blob
    state_blob=$(jq '{
        folderName: .metadata.folderName,
        documentationContext: (.metadata.documentationContext // ""),
        files: [.files[] | {
            id,
            relativePath,
            filename,
            extension,
            sizeBytes,
            sha256,
            category,
            sourceUrl,
            linkPreview,
            contentDuplicateOf,
            catalogMatches
        }]
    }' "$WORK_STATE_FILE")
    local user_message="Analyze this immutable file catalog. For every file ID, return proposed folder, filename, combined relative path, and rationale. Use null for unchanged fields. Respond with valid JSON only.\n\n$state_blob"

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
            temperature: 0.15,
            response_format: {
                type: "json_schema",
                json_schema: {
                    name: "three_d_file_plan",
                    strict: true,
                    schema: {
                        type: "object",
                        additionalProperties: false,
                        required: ["files"],
                        properties: {
                            files: {
                                type: "array",
                                items: {
                                    type: "object",
                                    additionalProperties: false,
                                    required: ["id", "proposed"],
                                    properties: {
                                        id: {type: "integer"},
                                        proposed: {
                                            type: "object",
                                            additionalProperties: false,
                                            required: ["folder", "filename", "path", "rationale"],
                                            properties: {
                                                folder: {type: ["string", "null"]},
                                                filename: {type: ["string", "null"]},
                                                path: {type: ["string", "null"]},
                                                rationale: {type: ["string", "null"]}
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }')

    debug_log_api "AGENTIC_REQUEST" "$payload"
    local response=$(get-ai-response "$payload")
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

    merge_agent_plan "$response"
    record_agent_cycle "Primary planning cycle"
}

persist_state_file() {
    log_divider "STATE PERSIST"
    if (( STATE_FILE_EPHEMERAL )); then
        log_info "Dry-run: agentic plan JSON not written to disk; emitting below"
        cat "$STATE_FILE"
        return
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    cp "$WORK_STATE_FILE" "$STATE_FILE"
    log_info "State written to $STATE_FILE"
}

is_safe_relative_path() {
    local relative_path="$1"
    [[ -n "$relative_path" && "$relative_path" != /* ]] || return 1

    local -a components
    components=("${(@s:/:)relative_path}")
    local component
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    done

    local root candidate
    root="${INPUT_PATH:A}"
    candidate="${INPUT_PATH}/${relative_path}"
    candidate="${candidate:A}"
    [[ "$candidate" == "$root"/* ]]
}

resolve_destination_path() {
    local proposed_path="$1"
    local proposed_folder="$2"
    local proposed_filename="$3"
    local current_relative="$4"
    local fallback_name="$5"

    if [[ -n "$proposed_path" && "$proposed_path" != "null" ]]; then
        is_safe_relative_path "$proposed_path" || return 1
        echo "$proposed_path"
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
        is_safe_relative_path "$filename_component" || return 1
        echo "$filename_component"
    else
        local destination_relative="$folder_component/$filename_component"
        is_safe_relative_path "$destination_relative" || return 1
        echo "$destination_relative"
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
    local relative_path="$2"
    local existing_relative="$3"

    local tmp
    tmp=$(mktemp)
    jq --arg id "$file_id" --arg relative "$relative_path" --arg dup "$existing_relative" \
        '.metadata.duplicates += [{ fileId: ($id|tonumber), relativePath: $relative, duplicateOf: $dup, type: "content" }]' \
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
    local file_id relative_path proposed_path proposed_folder proposed_filename
    local original_path fallback_name destination_relative destination destination_dir
    local final_destination attempt base ext final_relative tmp
    while IFS=$'\x1f' read -r file_id relative_path proposed_path proposed_folder proposed_filename; do
        [[ -z "$relative_path" || "$relative_path" == "null" ]] && continue
        if ! is_safe_relative_path "$relative_path"; then
            log_error "Unsafe inventory path rejected: $relative_path"
            return 1
        fi

        original_path="${INPUT_PATH}/${relative_path}"
        if [[ -L "$original_path" ]]; then
            log_error "Symlinked inventory source rejected: $relative_path"
            return 1
        fi
        if [[ ! -e "$original_path" ]]; then
            log_warn "Original file missing, skipping: $relative_path"
            continue
        fi

        fallback_name="$(basename "$original_path")"
        if ! destination_relative=$(resolve_destination_path "$proposed_path" "$proposed_folder" "$proposed_filename" "$relative_path" "$fallback_name"); then
            log_error "Unsafe proposed destination rejected for $relative_path"
            return 1
        fi
        destination="${INPUT_PATH}/${destination_relative}"

        if [[ -z "$destination" ]]; then
            log_warn "No destination resolved for $relative_path; skipping"
            continue
        fi
        if [[ "$original_path" == "$destination" ]]; then
            continue
        fi

        if [[ -e "$destination" ]] && files_identical "$original_path" "$destination"; then
            log_info "Duplicate detected; skipping move for $original_path (matches $destination)"
            record_duplicate_detection "$file_id" "$relative_path" "$destination_relative"
            continue
        fi

        destination_dir="$(dirname "$destination")"
        mkdir -p "$destination_dir"

        final_destination="$destination"
        attempt=1
        while [[ -e "$final_destination" ]]; do
            base="$(basename "$destination")"
            ext=""
            if [[ "$base" == *.* ]]; then
                ext=".${base##*.}"
                base="${base%.*}"
            fi
            final_destination="$destination_dir/${base}_agentic${attempt}${ext}"
            attempt=$((attempt + 1))
        done

        mv "$original_path" "$final_destination"
        applied=$((applied + 1))
        final_relative="${final_destination#$INPUT_PATH/}"

        tmp=$(mktemp)
        jq --arg id "$file_id" --arg path "$final_relative" \
            '(.files[] | select((.id|tostring) == $id)) |= (.appliedPath = $path)' \
            "$STATE_FILE" >"$tmp"
        mv "$tmp" "$STATE_FILE"
        log_info "Moved $(basename "$original_path") -> $final_relative"
    done < <(jq -r '.files[] | [(.id|tostring), .relativePath, (.proposed.path // ""), (.proposed.folder // ""), (.proposed.filename // "")] | join("\u001f")' "$STATE_FILE")

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
        response=$(get-ai-response "$payload")
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

    archive_category=$(canonicalize_archive_category "$archive_category" "$folder_structure_json")
    archive_subcategory=$(canonicalize_archive_subcategory "$archive_subcategory" "$archive_category" "$folder_structure_json")
    archive_folder=$(sanitize_folder_component "$archive_folder")

    local tmp=$(mktemp)
    jq --arg category "$archive_category" \
       --arg sub "$archive_subcategory" \
       --arg folder "$archive_folder" \
       --arg rationale "$rationale" \
       '.metadata.archivePlan = {
           category: $category,
           subcategory: $sub,
           folderName: $folder,
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

    archive_category=$(sanitize_existing_folder_component "$archive_category")
    archive_subcategory=$(sanitize_existing_folder_component "$archive_subcategory")
    archive_folder=$(sanitize_existing_folder_component "$archive_folder")

    local exact_duplicate_relative exact_duplicate_path
    exact_duplicate_relative=$(command jq -r '.metadata.catalog.exactDuplicateProject.relativePath // empty' "$STATE_FILE")
    exact_duplicate_path="$BASE_PATH/$exact_duplicate_relative"
    if [[ -n "$exact_duplicate_relative" && ! -d "$exact_duplicate_path" ]]; then
        log_warn "Catalog exact-duplicate target is missing; proceeding with a normal archive move"
        exact_duplicate_relative=""
    fi
    if [[ -n "$exact_duplicate_relative" ]] && ! is_safe_archive_destination "$exact_duplicate_path"; then
        log_error "Unsafe catalog duplicate destination rejected: $exact_duplicate_relative"
        return 1
    fi
    if [[ -n "$exact_duplicate_relative" ]]; then
        local exact_category exact_subcategory exact_folder
        local source_resolved target_resolved
        exact_category=$(command jq -r '.metadata.catalog.exactDuplicateProject.category' "$STATE_FILE")
        exact_subcategory=$(command jq -r '.metadata.catalog.exactDuplicateProject.subcategory' "$STATE_FILE")
        exact_folder=$(command jq -r '.metadata.catalog.exactDuplicateProject.folderName' "$STATE_FILE")
        source_resolved="${INPUT_PATH:A}"
        target_resolved="${exact_duplicate_path:A}"
        if [[ "$source_resolved" == "$target_resolved" ]]; then
            local already_archived_tmp
            already_archived_tmp=$(command mktemp)
            command jq \
                --arg path "$exact_duplicate_relative" \
                --arg category "$exact_category" \
                --arg subcategory "$exact_subcategory" \
                --arg folder "$exact_folder" \
                '.metadata.archivePlan |= (
                    .category = $category |
                    .subcategory = $subcategory |
                    .folderName = $folder |
                    .destinationPath = $path |
                    .disposition = "already-archived"
                )' "$STATE_FILE" >"$already_archived_tmp"
            command mv "$already_archived_tmp" "$STATE_FILE"
            log_info "Input is already the canonical archived project; leaving it in place"
            return 0
        fi
        if [[ "$source_resolved" == "$target_resolved"/* || "$target_resolved" == "$source_resolved"/* ]]; then
            log_error "Overlapping source and canonical project paths cannot be duplicate-suppressed"
            return 1
        fi
        if (( DRY_RUN )); then
            local duplicate_tmp
            duplicate_tmp=$(command mktemp)
            command jq \
                --arg path "$exact_duplicate_relative" \
                --arg category "$exact_category" \
                --arg subcategory "$exact_subcategory" \
                --arg folder "$exact_folder" \
                '.metadata.archivePlan |= (
                    .category = $category |
                    .subcategory = $subcategory |
                    .folderName = $folder |
                    .destinationPath = $path |
                    .disposition = "exact-duplicate"
                )' "$STATE_FILE" >"$duplicate_tmp"
            command mv "$duplicate_tmp" "$STATE_FILE"
            log_info "Dry-run: exact duplicate would reuse $BASE_PATH/$exact_duplicate_relative"
            return 0
        fi

        if (( SKIP_BACKUP )) || [[ -z "$BACKUP_ARCHIVE" || ! -s "$BACKUP_ARCHIVE" ]] ||
            ! command unzip -tq "$BACKUP_ARCHIVE" >/dev/null 2>&1; then
            log_warn "Exact duplicate suppression requires a recovery archive; proceeding with a normal archive move"
        elif ! directory_hash_inventory_matches_state "$exact_duplicate_path" "$STATE_FILE"; then
            log_warn "Catalog exact-duplicate target no longer matches on disk; proceeding with a normal archive move"
        elif ! directory_hash_inventory_matches_state "$INPUT_PATH" "$STATE_FILE"; then
            log_warn "Duplicate input changed after inventory; preserving it with a normal archive move"
        else
            local receipt_path receipt_tmp
            receipt_path="$RECOVERY_ROOT/$IMPORT_ID/duplicate-import.json"
            receipt_tmp="$receipt_path.tmp.$$"
            command mkdir -p "$(dirname "$receipt_path")"
            command jq \
                --arg path "$exact_duplicate_relative" \
                --arg category "$exact_category" \
                --arg subcategory "$exact_subcategory" \
                --arg folder "$exact_folder" \
                '.metadata.archivePlan |= (
                    .category = $category |
                    .subcategory = $subcategory |
                    .folderName = $folder |
                    .destinationPath = $path |
                    .disposition = "exact-duplicate"
                )' "$STATE_FILE" >"$receipt_tmp"
            command mv "$receipt_tmp" "$receipt_path"
            if ! command rm -rf "$INPUT_PATH" || [[ -e "$INPUT_PATH" ]]; then
                log_error "Could not remove the recovered duplicate input at $INPUT_PATH"
                return 1
            fi
            INPUT_PATH="$BASE_PATH/$exact_duplicate_relative"
            STATE_FILE="$receipt_path"
            log_info "Exact duplicate suppressed; recovery receipt written to $receipt_path"
            return 0
        fi
    fi

    local category_dir="$BASE_PATH/$archive_category"
    local target_dir="$category_dir/$archive_subcategory"
    local intended_destination="$target_dir/$archive_folder"
    local resolved_destination relative_destination

    if ! is_safe_archive_destination "$intended_destination"; then
        log_error "Unsafe archive destination rejected: $intended_destination"
        return 1
    fi
    if [[ "${INPUT_PATH:A}" == "${intended_destination:A}" ]]; then
        relative_destination="${intended_destination#$BASE_PATH/}"
        local existing_tmp
        existing_tmp=$(command mktemp)
        command jq --arg path "$relative_destination" \
            '.metadata.archivePlan.destinationPath = $path |
             .metadata.archivePlan.disposition = "already-archived"' \
            "$STATE_FILE" >"$existing_tmp"
        command mv "$existing_tmp" "$STATE_FILE"
        log_info "Input already occupies its planned archive destination; leaving it in place"
        return 0
    fi

    if (( DRY_RUN )); then
        resolved_destination=$(resolve_unique_archive_destination "$target_dir" "$archive_folder")
        if ! is_safe_archive_destination "$resolved_destination"; then
            log_error "Unsafe archive destination rejected: $resolved_destination"
            return 1
        fi
        relative_destination="${resolved_destination#$BASE_PATH/}"
        log_info "Dry-run: folder would be moved to $resolved_destination"
        local tmp=$(mktemp)
        jq --arg path "$relative_destination" '.metadata.archivePlan.destinationPath = $path' "$STATE_FILE" >"$tmp"
        mv "$tmp" "$STATE_FILE"
        return
    fi

    resolved_destination=$(resolve_unique_archive_destination "$target_dir" "$archive_folder")
    if ! is_safe_archive_destination "$resolved_destination"; then
        log_error "Unsafe archive destination rejected: $resolved_destination"
        return 1
    fi
    mkdir -p "$target_dir"
    relative_destination="${resolved_destination#$BASE_PATH/}"

    log_info "Moving organized folder to archive: $resolved_destination"
    mv "$INPUT_PATH" "$resolved_destination"
    invalidate_archive_cache "$BASE_PATH"

    INPUT_PATH="$resolved_destination"
    STATE_FILE="$resolved_destination/$DEFAULT_STATE_FILENAME"

    local tmp
    tmp=$(mktemp)
    jq --arg dest "$relative_destination" \
        '.metadata.archivePlan.destinationPath = $dest' \
        "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

generate_summary_report() {
    log_divider "SUMMARY"
    if [[ ! -f "$STATE_FILE" ]]; then
        log_warn "State file missing; skipping summary report"
        return
    fi

    local summary_dir summary_path summary_data
    summary_dir="$(dirname "$STATE_FILE")"
    summary_path="$summary_dir/$SUMMARY_FILENAME"
    summary_data=$(jq '{
        folderName: .metadata.folderName,
        generatedAt: .metadata.generatedAt,
        dryRun: (.metadata.dryRun // false),
        recovery: (.metadata.recovery // null),
        totalFiles: (.metadata.totalFiles // 0),
        plannedMoves: ([.files[] | select(.proposed.path != null or .proposed.folder != null or .proposed.filename != null)] | length),
        appliedMoves: ([.files[] | select((.appliedPath? // null) != null)] | length),
        duplicates: (.metadata.duplicates // []),
        archivePlan: (.metadata.archivePlan // {}),
        agentCycles: (.metadata.agentCycles // []),
        documentationContext: (.metadata.documentationContext // ""),
        plannedPreview: ([
            .files[]
            | select(.proposed.path != null or .proposed.folder != null or .proposed.filename != null)
            | {
                source: (.relativePath // "(unknown)"),
                destination: (
                    .proposed.path //
                    (if .proposed.folder != null and .proposed.filename != null then .proposed.folder + "/" + .proposed.filename
                     elif .proposed.filename != null then .proposed.filename
                     else .relativePath end) // "(unchanged)"
                )
            }
        ] | .[:10])
    }' "$STATE_FILE")

    local folder_name generated_at dry_run_flag dry_run_text backup_zip total_files planned_moves applied_moves duplicate_count
    folder_name=$(jq -r '.folderName' <<<"$summary_data")
    generated_at=$(jq -r '.generatedAt' <<<"$summary_data")
    dry_run_flag=$(jq -r '.dryRun' <<<"$summary_data")
    dry_run_text=$([[ "$dry_run_flag" == "true" ]] && echo "Yes" || echo "No")
    backup_zip=$(jq -r 'if .recovery == null then "None" else .recovery.id + "/" + .recovery.archiveName end' <<<"$summary_data")
    total_files=$(jq -r '.totalFiles' <<<"$summary_data")
    planned_moves=$(jq -r '.plannedMoves' <<<"$summary_data")
    applied_moves=$(jq -r '.appliedMoves' <<<"$summary_data")
    duplicate_count=$(jq -r '.duplicates | length' <<<"$summary_data")

    local archive_category archive_subcategory archive_folder archive_destination archive_rationale
    archive_category=$(jq -r '.archivePlan.category // "Uncategorized"' <<<"$summary_data")
    archive_subcategory=$(jq -r '.archivePlan.subcategory // "Needs Review"' <<<"$summary_data")
    archive_folder=$(jq -r '.archivePlan.folderName // .folderName // ""' <<<"$summary_data")
    archive_destination=$(jq -r '.archivePlan.destinationPath // "(pending)"' <<<"$summary_data")
    archive_rationale=$(jq -r '.archivePlan.rationale // ""' <<<"$summary_data")

    local agent_cycles_section
    agent_cycles_section=$(jq -r --arg fallback "$generated_at" '
        def entry($item):
            if ($item | type) == "object" then
                "- " + ($item.description // "Agent cycle") + " (" + (($item.completedAt // $fallback) // "time unknown") + ")"
            else
                "- " + ($item | tostring)
            end;
        if (.agentCycles | length) == 0 then "None recorded"
        else (.agentCycles | map(entry(.)) | join("\n"))
        end
    ' <<<"$summary_data")

    local planned_preview_table
    planned_preview_table=$(jq -r '
        def esc(str):
            (str // "(unknown)")
            | gsub("\\|"; "\\|")
            | gsub("\n"; " / ");
        if (.plannedPreview | length) == 0 then ""
        else
            (["| Original | Proposed |", "| --- | --- |"] +
             (.plannedPreview | map("| " + esc(.source) + " | " + esc(.destination) + " |")))
            | join("\n")
        end
    ' <<<"$summary_data")

    local duplicates_section
    duplicates_section=$(jq -r '
        def esc(str): (str // "unknown") | gsub("`"; "\\`");
        if (.duplicates | length) == 0 then ""
        else
            (["## Duplicates", ""] +
             (.duplicates | map("- " + (.type // "file") + ": `" + esc(.relativePath // .url) + "` duplicate of `" + esc(.duplicateOf // .url) + "`")))
            | join("\n")
        end
    ' <<<"$summary_data")

    local doc_context doc_display doc_block
    doc_context=$(jq -r '.documentationContext' <<<"$summary_data")
    if [[ "$doc_context" != "null" && -n "$doc_context" ]]; then
        local max_doc_chars=600
        doc_display="${doc_context:0:$max_doc_chars}"
        if (( ${#doc_context} > max_doc_chars )); then
            doc_display+="…"
        fi
        doc_block=$(printf '%s' "$doc_display" | sed 's/^/> /')
    else
        doc_block=""
    fi

    local summary_output
    summary_output=$(
        {
            printf '# 3D Import Summary\n\n'
            printf -- '- **Folder:** `%s`\n' "$folder_name"
            printf -- '- **Run Date:** %s\n' "$generated_at"
            printf -- '- **Dry Run:** %s\n' "$dry_run_text"
            printf -- '- **Backup ZIP:** %s\n' "$backup_zip"
            printf -- '- **Total Files Indexed:** %s\n' "$total_files"
            printf -- '- **Planned Moves:** %s\n' "$planned_moves"
            printf -- '- **Applied Moves:** %s\n' "$applied_moves"
            printf -- '- **Duplicates Logged:** %s\n\n' "$duplicate_count"

            printf '## Archive Plan\n\n'
            printf -- '- **Category:** %s\n' "$archive_category"
            printf -- '- **Subcategory:** %s\n' "$archive_subcategory"
            printf -- '- **Project Folder:** %s\n' "$archive_folder"
            printf -- '- **Destination Path:** %s\n' "$archive_destination"
            if [[ -n "$archive_rationale" && "$archive_rationale" != "null" ]]; then
                printf -- '- **Rationale:** %s\n' "$archive_rationale"
            fi

            printf '\n## Agent Cycles\n\n%s\n' "$agent_cycles_section"

            if [[ -n "$planned_preview_table" ]]; then
                printf '\n## Planned Moves Preview\n\n%s\n' "$planned_preview_table"
            fi

            if [[ -n "$doc_block" ]]; then
                printf '\n## Documentation Context\n\n%s\n' "$doc_block"
            fi

            if [[ -n "$duplicates_section" ]]; then
                printf '\n%s\n' "$duplicates_section"
            fi
        }
    )

    if (( DRY_RUN )); then
        log_info "Dry-run: summary report not written to disk; emitting below"
        printf '%s\n' "$summary_output"
    else
        printf '%s\n' "$summary_output" >"$summary_path"
        log_info "Summary report written to $summary_path"
    fi
}

finalize_3d_catalog() {
    log_divider "CATALOG UPDATE"
    local disposition destination category subcategory
    disposition=$(command jq -r '.metadata.archivePlan.disposition // "archived"' "$STATE_FILE")
    destination=$(command jq -r '.metadata.archivePlan.destinationPath // empty' "$STATE_FILE")
    category=$(command jq -r '.metadata.archivePlan.category // "Unsorted"' "$STATE_FILE")
    subcategory=$(command jq -r '.metadata.archivePlan.subcategory // "Needs Review"' "$STATE_FILE")

    if [[ "$disposition" == "exact-duplicate" ]]; then
        record_3d_catalog_event "$IMPORT_ID" "$disposition" "" "$destination" ||
            log_warn "Could not record exact-duplicate catalog event"
    else
        if index_3d_project_from_state "$STATE_FILE" "$INPUT_PATH" "valid"; then
            record_3d_catalog_event "$IMPORT_ID" "$disposition" "$destination" "" ||
                log_warn "Could not record archive catalog event"
            apply_3d_project_finder_tags "$INPUT_PATH" "$category" "$subcategory" ||
                log_warn "Could not apply optional Finder tags to $INPUT_PATH"
        else
            log_warn "Catalog indexing failed; the archived project will be repaired by backfill"
        fi
    fi

    render_3d_catalog_html || log_warn "Catalog HTML regeneration failed"
    write_3d_catalog_health_report || log_warn "Catalog health report regeneration failed"
    return 0
}

reveal_result_folder() {
    if [[ "${ORGANIZE_3D_NO_REVEAL:-0}" == "1" ]]; then
        log_info "Finder reveal disabled"
        return
    fi

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
    if (( STATE_FILE_EPHEMERAL )); then
        [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] && rm -f "$STATE_FILE"
    else
        [[ -n "$WORK_STATE_FILE" && -f "$WORK_STATE_FILE" && "$WORK_STATE_FILE" != "$STATE_FILE" ]] && rm -f "$WORK_STATE_FILE"
    fi
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
    annotate_archive_catalog_matches
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
    generate_summary_report
    finalize_3d_catalog
    reveal_result_folder
}

if [[ "${ORGANIZE_3D_LIBRARY_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
