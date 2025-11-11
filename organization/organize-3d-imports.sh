#!/usr/bin/env zsh

# Set Shell Options
setopt extended_glob
setopt null_glob

set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# ============================================================================
# CONFIGURATION AND ENVIRONMENT SETUP
# ============================================================================

# Validate required environment
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# Configuration variables
readonly BASE_PATH="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-DEBUG}"
readonly PDF_TEXT_LIMIT="${PDF_TEXT_LIMIT:-100}"
readonly README_TEXT_LIMIT="${README_TEXT_LIMIT:-50}"
typeset -A FILE_COUNTERS
typeset -a CONTEXT_KEYWORDS
typeset -a WEBLOC_REFERENCES

# Validate input argument early
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <directory_path>" >&2
    echo "Please provide a directory path to organize" >&2
    exit 1
fi

readonly INPUT_PATH="$1"
readonly NAME="$(basename "$INPUT_PATH")"

# Validate that the input path exists and is a directory
if [[ ! -d "$INPUT_PATH" ]]; then
    echo "Error: '$INPUT_PATH' does not exist or is not a directory" >&2
    exit 1
fi

# Ensure base path exists for logging
if [[ ! -d "$BASE_PATH" ]]; then
    mkdir -p "$BASE_PATH"
fi

# Initialize logging utility
export LOG_LEVEL=0
export LOG_FD=2
source "$SCRIPT_DIR/../utilities/logging.sh"
setup_script_logging
set_log_level "$LOG_LEVEL_NAME"

# Log header to mark new session start
log_header "organize-3d-imports.sh"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Clean content by removing control characters and normalizing whitespace
clean_content() {
    local content="$1"
    printf '%s' "$content" | tr -d '\000-\037\177' | tr -cd '[:print:][:space:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# Check if file matches known text extensions
is_text_file() {
    local filename="$1"
    local lowercase_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
    local extension="${lowercase_name##*.}"

    [[ "$extension" =~ ^(txt|md|rst|html|htm)$ ]] || [[ "$filename" == "$extension" ]]
}

# Check if file is a documentation file or webloc that should stay at root
is_special_doc_file() {
    local filename="$1"
    local lowercase_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')

    # Check for special doc files (readme, license, summary)
    [[ "$lowercase_name" =~ ^(readme|license|summary)(\.|$) ]] && return 0

    # Check for webloc files
    [[ "$lowercase_name" == *.webloc ]] && return 0

    # Check for JSON files
    [[ "$lowercase_name" == *.json ]] && return 0

    return 1
}

# Get file list as comma-separated string
get_file_list() {
    find "$1" -type f -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//'
}

get_webloc_url() {
    local webloc_file="$1"
    local url=""

    if command -v plutil >/dev/null 2>&1; then
        url=$(plutil -extract URL raw "$webloc_file" 2>/dev/null || true)
        if [[ -z "$url" ]]; then
            url=$(plutil -p "$webloc_file" 2>/dev/null | awk -F'"' '/URL/ {print $4; exit}')
        fi
    fi

    if [[ -z "$url" ]]; then
        url=$(grep -Eo '<string>[^<]+' "$webloc_file" 2>/dev/null | head -1 | sed 's/<string>//')
    fi

    printf '%s' "$url"
}

describe_file_type() {
    local extension="${1:l}"

    case "$extension" in
        stl|obj|3mf|step|stp|f3d|blend|scad|shapr) echo "3D Model" ;;
        gcode) echo "Print Export" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) echo "Image" ;;
        pdf|md|txt|rtf|html|htm|doc) echo "Documentation" ;;
        *) echo "" ;;
    esac
}

build_file_inventory() {
    local file_list="$1"
    local -a file_array
    local inventory=""

    file_array=("${(@s/,/)file_list}")

    for file_name in "${file_array[@]}"; do
        [[ -z "$file_name" ]] && continue
        local extension=""
        if [[ "$file_name" == *.* ]]; then
            extension="${file_name##*.}"
        fi
        local type_description="$(describe_file_type "$extension")"
        if [[ -n "$type_description" ]]; then
            inventory+=" - $file_name ($type_description)\n"
        else
            inventory+=" - $file_name\n"
        fi
    done

    echo "$inventory"
}

normalize_for_comparison() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g'
}

is_generic_name() {
    local name="$1"
    local sanitized=$(echo "$name" | tr '[:punct:]' ' ' | tr -s ' ' ' ')
    local -a tokens
    local generic_list=" file files model models part parts object objects obj copy source mesh export version final item items piece pieces component components print printout file1 file2 "

    tokens=(${=sanitized})

    for token in "${tokens[@]}"; do
        local lower=$(echo "$token" | tr '[:upper:]' '[:lower:]')
        if [[ -z "$lower" ]]; then
            continue
        fi
        if [[ "$lower" =~ ^[0-9]+$ ]]; then
            continue
        fi
        if [[ ${#lower} -ge 4 && "$generic_list" != *" $lower "* ]]; then
            return 1
        fi
    done

    return 0
}

contains_context_keyword() {
    local name_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    for keyword in "${CONTEXT_KEYWORDS[@]}"; do
        if [[ -n "$keyword" && "$name_lower" == *"$keyword"* ]]; then
            return 0
        fi
    done

    return 1
}

set_context_keywords() {
    CONTEXT_KEYWORDS=()

    local title="$1"
    local sanitized=$(echo "$title" | tr '-' ' ' | tr '/' ' ' | tr '[:punct:]' ' ' | tr -s ' ' ' ')
    local -a words

    words=(${=sanitized})

    for word in "${words[@]}"; do
        local lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
        if [[ ${#lower} -ge 4 && "$lower" != "files" && "$lower" != "custom" ]]; then
            CONTEXT_KEYWORDS+=("$lower")
        fi
    done
}

label_for_extension() {
    local extension="${1:l}"
    local subfolder="$2"

    case "$extension" in
        stl|obj|3mf|step|stp|f3d|blend|scad|shapr) echo "Component" ;;
        gcode) echo "Gcode" ;;
        jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) echo "Image" ;;
        pdf|md|txt|rtf|html|htm|doc) echo "Document" ;;
        *)
            if [[ "$subfolder" == "exports" ]]; then
                echo "Export"
            else
                echo "File"
            fi
            ;;
    esac
}

generate_semantic_basename() {
    local original_name="$1"
    local extension="$2"
    local target_subfolder="$3"

    local context_title="$proposed_name"
    [[ -z "$context_title" ]] && context_title="$NAME"

    local sanitized_context=$(echo "$context_title" | tr '/' ' ' | tr -s ' ' ' ')
    local -a context_words
    local -a selected_words

    context_words=(${=sanitized_context})

    if (( ${#CONTEXT_KEYWORDS[@]} > 0 )); then
        for word in "${context_words[@]}"; do
            local lower_word=$(echo "$word" | tr '[:upper:]' '[:lower:]')
            for keyword in "${CONTEXT_KEYWORDS[@]}"; do
                if [[ "$lower_word" == "$keyword" ]]; then
                    local clean_word=$(echo "$word" | sed 's/[^A-Za-z0-9]//g')
                    if [[ -n "$clean_word" ]]; then
                        selected_words+=("$clean_word")
                    fi
                    break
                fi
            done
            if (( ${#selected_words[@]} >= 3 )); then
                break
            fi
        done
    fi

    if (( ${#selected_words[@]} == 0 )); then
        for word in "${context_words[@]}"; do
            local clean_word=$(echo "$word" | sed 's/[^A-Za-z0-9]//g')
            if [[ -z "$clean_word" ]]; then
                continue
            fi
            selected_words+=("$clean_word")
            if (( ${#selected_words[@]} >= 3 )); then
                break
            fi
        done
    fi

    if (( ${#selected_words[@]} == 0 )); then
        selected_words+=("Project")
    fi

    local descriptor="${(j: :)selected_words}"
    local type_label="$(label_for_extension "$extension" "$target_subfolder")"
    local counter_key="${target_subfolder}_${extension:l}"
    local counter=$(( ${FILE_COUNTERS[$counter_key]:-0} + 1 ))
    FILE_COUNTERS[$counter_key]=$counter

    local padded_index=$(printf "%02d" "$counter")
    local numeric_hint=$(echo "$original_name" | grep -oE '[0-9]{1,3}' | head -1)
    if [[ -n "$numeric_hint" ]]; then
        numeric_hint=$(printf "%02d" "$numeric_hint")
    else
        numeric_hint="$padded_index"
    fi

    local base_name="$descriptor $type_label $numeric_hint"
    base_name=$(echo "$base_name" | sed 's/  */ /g' | sed 's/[[:space:]]*$//')

    echo "$base_name"
}

sanitize_filename_component() {
    local component="$1"
    component=$(echo "$component" | sed 's/[\/:*?"<>|]/-/g')
    component=$(echo "$component" | tr -s ' ' ' ')
    component=$(echo "$component" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    component=$(echo "$component" | sed 's/[. ]$//')
    echo "$component"
}

needs_semantic_name() {
    local original_name="$1"
    local proposed_base="$2"

    if [[ -z "$proposed_base" ]]; then
        return 0
    fi

    local original_simple="$(normalize_for_comparison "$original_name")"
    local proposed_simple="$(normalize_for_comparison "$proposed_base")"

    if [[ "$original_simple" == "$proposed_simple" ]]; then
        return 0
    fi

    if is_generic_name "$proposed_base"; then
        return 0
    fi

    if (( ${#CONTEXT_KEYWORDS[@]} > 0 )); then
        if contains_context_keyword "$proposed_base"; then
            return 1
        else
            return 0
        fi
    fi

    return 1
}

# Collect non-3MF file extensions that should go into the files directory
collect_files_extensions() {
    local folder_path="$1"
    local -A extensions_found

    # Define 3D model extensions (excluding 3MF which stays at files root)
    local -a model_extensions=(stl obj step stp f3d blend scad shapr)

    # Scan all files in the folder
    for file in "$folder_path"/*; do
        if [[ -f "$file" ]]; then
            local basename=$(basename "$file")
            local extension="${basename##*.}"
            local lowercase_ext=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

            # Check if this extension is a non-3MF model extension
            for model_ext in "${model_extensions[@]}"; do
                if [[ "$lowercase_ext" == "$model_ext" ]]; then
                    extensions_found[$lowercase_ext]=1
                    break
                fi
            done
        fi
    done

    # Return the list of extensions found
    echo "${(k)extensions_found[@]}"
}

# Get the subdirectory name for a file extension
get_extension_subdirectory() {
    local extension="$1"
    local lowercase_ext=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

    case "$lowercase_ext" in
        stl) echo "STLs" ;;
        obj) echo "OBJs" ;;
        step|stp) echo "STEPs" ;;
        f3d) echo "F3Ds" ;;
        blend) echo "Blenders" ;;
        scad) echo "SCADs" ;;
        shapr) echo "Shaprs" ;;
        *) echo "" ;;
    esac
}

# ============================================================================
# AI INTEGRATION FUNCTIONS
# ============================================================================

# OpenAI system message for organization
readonly OPENAI_SYSTEM_MESSAGE="You are an expert 3D printing file organization specialist. Your role is to:

1. Analyze 3D printing project files and their context
2. Create logical, hierarchical folder structures for long-term organization
3. Generate descriptive, consistent file names that preserve important identifiers
4. Categorize files by type and purpose for optimal workflow

You have deep knowledge of:
- 3D printing file formats (.stl, .3mf, .step, .gcode, etc.)
- Common 3D printing brands, products, and part numbering systems
- File organization best practices for maker/engineering workflows
- Preserving technical identifiers while improving readability
- If there are non-English names or characters, translate the names to English

Always prioritize consistency, discoverability, and preservation of important technical information."

extract_documentation_content() {
    local folder_path="$1"
    local content=""
    WEBLOC_REFERENCES=()
    log_debug "Extracting documentation from: $folder_path"

    # Process README files
    for readme_file in "$folder_path"/README* "$folder_path"/readme* "$folder_path"/Readme*; do
        if [[ -f "$readme_file" ]]; then
            local basename=$(basename "$readme_file")
            if is_text_file "$basename" && [[ "$(echo "$basename" | tr '[:upper:]' '[:lower:]')" =~ ^readme(\.|$) ]]; then
                local readme_content=$(cat "$readme_file" 2>/dev/null | head -"$README_TEXT_LIMIT")
                if [[ -n "$readme_content" ]]; then
                    content="$content\n\n=== README ($basename) ===\n$readme_content"
                fi
            fi
        fi
    done

    # Process PDF files
    if command -v pdftotext >/dev/null 2>&1; then
        for pdf_file in "$folder_path"/*.pdf "$folder_path"/*.PDF; do
            if [[ -f "$pdf_file" ]]; then
                local basename=$(basename "$pdf_file")
                local pdf_content=$(pdftotext "$pdf_file" - 2>/dev/null | head -"$PDF_TEXT_LIMIT")
                if [[ -n "$pdf_content" ]]; then
                    content="$content\n\n=== PDF ($basename) ===\n$pdf_content"
                fi
            fi
        done
    else
        # Count PDF files and suggest installation if needed
        local pdf_count=$(find "$folder_path" -maxdepth 1 -name "*.pdf" -o -name "*.PDF" | wc -l)
        if [[ $pdf_count -gt 0 ]]; then
            log_warn "Found $pdf_count PDF file(s) but pdftotext unavailable"
            log_info "Install poppler-utils: brew install poppler"
            content="$content\n\n=== PDF FILES FOUND ===\n[${pdf_count} PDF file(s) present - install poppler-utils for content extraction]"
        fi
    fi

    # Process other text documentation
    for doc_file in "$folder_path"/*.{txt,md,rtf,TXT,MD,RTF}; do
        if [[ -f "$doc_file" ]]; then
            local basename=$(basename "$doc_file")
            local lowercase_basename=$(echo "$basename" | tr '[:upper:]' '[:lower:]')

            # Skip README files (already processed)
            if [[ ! "$lowercase_basename" =~ ^readme(\.|$) ]]; then
                local doc_content=""

                if [[ "$lowercase_basename" =~ \.rtf$ ]]; then
                    if command -v unrtf >/dev/null 2>&1; then
                        doc_content=$(unrtf --text "$doc_file" 2>/dev/null | head -"$README_TEXT_LIMIT")
                    else
                        log_warn "RTF file found but unrtf unavailable: $basename"
                        doc_content="[RTF file - install unrtf: brew install unrtf]"
                    fi
                else
                    doc_content=$(cat "$doc_file" 2>/dev/null | head -"$README_TEXT_LIMIT")
                fi

                if [[ -n "$doc_content" ]]; then
                    content="$content\n\n=== TEXT DOC ($basename) ===\n$doc_content"
                fi
            fi
        fi
    done

    # Process WEBLOC link files (record URLs only)
    for webloc_file in "$folder_path"/*.webloc "$folder_path"/*.WEBLOC; do
        if [[ -f "$webloc_file" ]]; then
            local basename=$(basename "$webloc_file")
            local url=$(get_webloc_url "$webloc_file")

            if [[ -z "$url" ]]; then
                log_warn "Failed to extract URL from webloc file: $basename"
                WEBLOC_REFERENCES+=("$basename -> [missing URL]")
                continue
            fi

            WEBLOC_REFERENCES+=("$basename -> $url")
        fi
    done

    if [[ -n "$content" ]]; then
        local clean_content=$(clean_content "$content")
        if [[ -n "$clean_content" && "$clean_content" != " " ]]; then
            echo "$clean_content"
        fi
    fi
}

summarize_documentation() {
    local documentation_content="$1"

    if [[ -z "$documentation_content" ]]; then
        return
    fi

    log_info "Summarizing documentation for organization context"

    local cleaned_content=$(clean_content "$documentation_content")
    if [[ -z "$cleaned_content" ]]; then
        log_warn "Documentation content could not be processed safely"
        return
    fi

    local summary_system_message="You are a technical documentation analyst specializing in 3D printing projects. Extract key organizational metadata from documentation with precision and consistency."

    local summary_user_message="Analyze this 3D printing project documentation and extract ONLY the essential organizational information:

**REQUIRED OUTPUT FORMAT:**
Purpose: [What the models are designed for - be specific]
Identifiers: [Model numbers, part numbers, product names - exact format]
Application: [Target use case or device compatibility]
Brand/Series: [Brand names, product lines, or series names]
Specifications: [Key technical specs: sizes, versions, materials]

**RULES:**
- Extract exact identifiers (preserve case, formatting, version numbers)
- Focus on organizational metadata, not instructions
- If information is unclear, state \"Not specified\"
- Maximum 3 sentences total
- Be precise with technical terms

**DOCUMENTATION:**
$cleaned_content"

    # Create JSON payload with error handling
    local escaped_system escaped_user summary_json_payload
    if ! escaped_system=$(printf '%s' "$summary_system_message" | jq -R -s .); then
        log_error "Failed to escape system message"
        return
    fi

    if ! escaped_user=$(printf '%s' "$summary_user_message" | jq -R -s .); then
        log_error "Failed to escape user message"
        return
    fi

    summary_json_payload=$(jq -n \
        --argjson system_msg "$escaped_system" \
        --argjson user_msg "$escaped_user" \
        '{
            "messages": [
                {"role": "system", "content": $system_msg},
                {"role": "user", "content": $user_msg}
            ],
            "temperature": 0.1
        }')

    debug_log_api "SUMMARIZATION API REQUEST" "$summary_json_payload"
    local summary_response=$(get-openai-response "$summary_json_payload")
    debug_log_api "SUMMARIZATION API RESPONSE" "$summary_response"
    log_debug "Summarization API response length: ${#summary_response}"

    if [[ -n "$summary_response" && "$summary_response" != "null" ]]; then
        echo "$summary_response"
    else
        log_warn "Failed to summarize documentation"
        echo "$documentation_content"
    fi
}

get_folder_structure() {
    local base_path="$1"
    local structure=""

    if [[ ! -d "$base_path" ]]; then
        log_warn "Base path does not exist: $base_path"
        return 1
    fi

    # Get category structure
    for category in "$base_path"/*; do
        if [[ -d "$category" ]]; then
            local category_name=$(basename "$category")
            # Skip hidden/underscore folders
            if [[ "$category_name" =~ ^_ ]]; then
                continue
            fi
            structure="$structure$category_name:\n"

            # Get subfolders
            local subfolders=""
            for subfolder in "$category"/*; do
                if [[ -d "$subfolder" ]]; then
                    local subfolder_name=$(basename "$subfolder")
                    if [[ ! "$subfolder_name" =~ ^_ ]]; then
                        subfolders="$subfolders  - $subfolder_name\n"
                    fi
                fi
            done

            structure="$structure${subfolders:- - (no subfolders)\n}\n"
        fi
    done

    if [[ -z "$structure" ]]; then
        return 1
    fi

    echo -e "$structure"
}

organize_all_files() {
    local folder_name="$1"
    local folder_structure="$2"
    local file_list="$3"
    local documentation_content="$4"

    # Clean documentation content
    local cleaned_documentation=""
    if [[ -n "$documentation_content" ]]; then
        cleaned_documentation=$(clean_content "$documentation_content")
        if [[ -z "$cleaned_documentation" ]]; then
            log_warn "Documentation content could not be processed safely"
            cleaned_documentation=""
        fi
    fi

    local file_inventory="$(build_file_inventory "$file_list")"

    local webloc_context=""
    if (( ${#WEBLOC_REFERENCES[@]} > 0 )); then
        webloc_context="\n**Referenced Links:**\n"
        for webloc_entry in "${WEBLOC_REFERENCES[@]}"; do
            webloc_context+=" - $webloc_entry\n"
        done
    fi

    local user_message="# 3D Print File Organization Task

## CONTEXT
**Target Folder:** '$folder_name'
**Files to Organize:**
$file_inventory$webloc_context

## EXISTING STRUCTURE
$folder_structure"

    # Add documentation context if available
    if [[ -n "$cleaned_documentation" ]]; then
        user_message="$user_message

## PROJECT CONTEXT
$cleaned_documentation

**Important:** Use this context to make informed naming and categorization decisions."
    fi

    user_message="$user_message

## REQUIREMENTS

### 1. FOLDER NAMING
- Generate descriptive, title-case name
- Preserve acronyms (PETG, PLA, etc.)
- Format: \"Brand - Product\" for branded items
- Remove redundant terms (\"3D files\", \"Model Files\")
- Keep descriptive terms (\"Kit\", \"Template\", \"Bracket\")

### 2. CATEGORIZATION HIERARCHY
- **Parent Category:** Select from existing structure or suggest new category
- **Sub-Category:** Choose appropriate subfolder maintaining consistency

### 3. FILE NAMING RULES
- **CRITICAL:** Preserve all model/part numbers from original names
- Always include at least one descriptor from the proposed folder name or documentation context (e.g., brand, character, application)
- Replace placeholder tokens (obj_1, part1, copy) with meaningful component descriptors; if unsure, use "Component" + two-digit numbering (Component 01)
- Use Title Case with proper spacing and keep file extensions lowercase
- Maintain technical precision while improving readability and ensure names remain under 60 characters when possible

### 4. FILE ORGANIZATION
**Subfolders:**
- \"files/\" - 3D models (.stl, .f3d, .3mf, .step, .stp, .scad, .blend, .shapr)
- \"images/\" - Pictures (.jpg, .jpeg, .png, .heic, .heif, .bmp, .gif, .webp, .tif, .tiff)
- \"exports/\" - G-code (.gcode)
- \"misc/\" - Other non-documentation files
- \"root/\" - Documentation (.txt, .pdf, .html, .htm, .md, .rtf, .doc)

### 5. QUALITY CHECKS
- Proposed filenames must not be identical to the originals after removing punctuation and casing
- Ensure sequential files use consistent numbering (e.g., 01, 02, 03)
- Highlight any files that cannot be confidently described and provide best-effort naming

## OUTPUT REQUIREMENTS
Provide a complete, consistent organization plan."

    # Create JSON payload
    local escaped_system escaped_user
    if ! escaped_system=$(printf '%s' "$OPENAI_SYSTEM_MESSAGE" | jq -R -s .); then
        log_error "Failed to escape system message"
        return 1
    fi

    if ! escaped_user=$(printf '%s' "$user_message" | jq -R -s .); then
        log_error "Failed to escape user message"
        return 1
    fi

    local json_payload=$(jq -n \
        --argjson system_msg "$escaped_system" \
        --argjson user_msg "$escaped_user" \
        '{
            "messages": [
                {"role": "system", "content": $system_msg},
                {"role": "user", "content": $user_msg}
            ],
            "temperature": 0.2,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "ComprehensiveFileOrganization",
                    "strict": true,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "originalFolderName": {"type": "string"},
                            "proposedFolderName": {"type": "string"},
                            "parentCategory": {"type": "string"},
                            "subCategory": {"type": "string"},
                            "fileOrganization": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "originalFileName": {"type": "string"},
                                        "proposedFileName": {"type": "string"},
                                        "targetSubfolder": {
                                            "type": "string",
                                            "enum": ["files", "images", "exports", "misc", "root"]
                                        }
                                    },
                                    "required": ["originalFileName", "proposedFileName", "targetSubfolder"],
                                    "additionalProperties": false
                                }
                            }
                        },
                        "required": ["originalFolderName", "proposedFolderName", "parentCategory", "subCategory", "fileOrganization"],
                        "additionalProperties": false
                    }
                }
            }
        }')

    debug_log_api "ORGANIZATION API REQUEST" "$json_payload"
    get-openai-response "$json_payload"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log_info "Starting 3D print file organization script"
    log_debug "Input path: $INPUT_PATH"

    # Source AI helpers
    source "$SCRIPT_DIR/../ai/open-ai-functions.sh" || {
        log_error "Failed to source OpenAI functions"
        exit 1
    }

    # Get existing folder structure
    local folder_structure
    if folder_structure=$(get_folder_structure "$BASE_PATH"); then
        log_info "Existing folder structure detected"
    else
        log_info "No existing structure found - will suggest new categories"
        folder_structure="No existing categories found. Please suggest appropriate categories for 3D print organization."
    fi

    # Create backup
    create_backup

    # Flatten and prepare folder
    prepare_folder

    # Extract and process documentation
    process_documentation

    # Get AI organization plan
    get_organization_plan "$folder_structure"

    # Execute organization plan
    execute_organization_plan

    log_info "Organization complete!"
}

create_backup() {
    log_divider "BACKUP CREATION"
    log_info "Creating backup of original folder"

    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name="${NAME}_backup_${timestamp}.zip"
    backup_path="$BASE_PATH/$backup_name"

    cd "$(dirname "$INPUT_PATH")"
    if zip -r "$backup_path" "$(basename "$INPUT_PATH")" >/dev/null 2>&1; then
        log_info "Backup created: $backup_path"
    else
        log_warn "Failed to create backup, continuing..."
    fi
}

prepare_folder() {
    log_divider "FOLDER PREPARATION"
    log_info "Preparing folder for AI processing"

    # Remove OS-generated files
    find "$INPUT_PATH" -name ".DS_Store" -o -name "Thumbs.db" -o -name "thumbs.db" \
        -o -name "desktop.ini" -o -name ".localized" -o -name "._*" -delete 2>/dev/null || true

    # Flatten nested structure
    log_debug "Flattening nested folder structures"
    export INPUT_PATH
    find "$INPUT_PATH" -mindepth 2 -type f -exec sh -c '
        for file; do
            base_name="$(basename "$file")"
            new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_$base_name"

            # Handle filename conflicts
            counter=1
            while [ -e "$new_path" ]; do
                ext="${base_name##*.}"
                name="${base_name%.*}"
                if [ "$ext" = "$base_name" ]; then
                    new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_${name}_${counter}"
                else
                    new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_${name}_${counter}.${ext}"
                fi
                counter=$((counter + 1))
            done

            mv "$file" "$new_path"
        done
    ' sh {} +

    # Remove empty directories
    find "$INPUT_PATH" -mindepth 1 -type d -empty -delete

    # Get final file list
    full_file_list=$(get_file_list "$INPUT_PATH")
    if [[ -z "$full_file_list" ]]; then
        log_error "No files found after preparation"
        exit 1
    fi
    log_debug "Files to organize: $full_file_list"
}

process_documentation() {
    log_divider "CONTENT ANALYSIS"
    log_info "Analyzing folder documentation"

    local raw_content
    raw_content=$(extract_documentation_content "$INPUT_PATH")

    if [[ -n "$raw_content" ]]; then
        log_info "Documentation found, summarizing for context"

        if documentation_content=$(summarize_documentation "$raw_content"); then
            if [[ -n "$documentation_content" ]]; then
                log_info "Documentation summarized successfully"
                echo ""
                echo "DOCUMENTATION SUMMARY:"
                echo "====================="
                echo "$documentation_content"
                echo "====================="
                echo ""

                # Save summary
                echo "$documentation_content" > "$INPUT_PATH/SUMMARY.txt"
                log_info "Summary saved to SUMMARY.txt"
            else
                log_warn "Documentation summarization returned empty result"
                documentation_content=""
            fi
        else
            log_warn "Documentation summarization failed"
            documentation_content=""
        fi
    else
        log_info "No documentation content found"
        documentation_content=""
    fi
}

get_organization_plan() {
    local folder_structure="$1"

    log_divider "AI ORGANIZATION"
    log_info "Getting comprehensive organization plan from AI"

    ai_response=$(organize_all_files "$NAME" "$folder_structure" "$full_file_list" "$documentation_content")

    debug_log_api "ORGANIZATION AI RESPONSE" "$ai_response"
    log_debug "Organization AI response received (${#ai_response} characters)"

    if [[ -z "$ai_response" || "$ai_response" == "null" ]]; then
        log_error "No response received from OpenAI API"
        exit 1
    fi

    log_debug "AI response received (${#ai_response} characters)"

    # Validate JSON
    if ! echo "$ai_response" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON response from AI:"
        log_error "${ai_response:0:500}..."

        if [[ "$ai_response" == *"targetSub" ]] || [[ "$ai_response" != *"}" ]]; then
            log_warn "Response appears truncated - try organizing fewer files"
        fi
        exit 1
    fi

    # Parse essential fields
    proposed_name=$(echo "$ai_response" | jq -r '.proposedFolderName // empty')
    category=$(echo "$ai_response" | jq -r '.parentCategory // empty')
    subcategory=$(echo "$ai_response" | jq -r '.subCategory // empty')

    if [[ -z "$proposed_name" || "$proposed_name" == "null" || -z "$category" || "$category" == "null" || -z "$subcategory" || "$subcategory" == "null" ]]; then
        log_error "AI response missing required information"

        # Try fallback parsing for truncated responses
        if [[ "$ai_response" == *'"proposedFolderName"'* ]]; then
            log_info "Attempting fallback parsing..."
            proposed_name=$(echo "$ai_response" | grep -o '"proposedFolderName":"[^"]*"' | cut -d'"' -f4 | head -1)
            category=$(echo "$ai_response" | grep -o '"parentCategory":"[^"]*"' | cut -d'"' -f4 | head -1)
            subcategory=$(echo "$ai_response" | grep -o '"subCategory":"[^"]*"' | cut -d'"' -f4 | head -1)

            if [[ -n "$proposed_name" && -n "$category" && -n "$subcategory" ]]; then
                log_warn "Fallback parsing successful, file organization may be incomplete"
            else
                log_error "Fallback parsing failed"
                exit 1
            fi
        else
            exit 1
        fi
    fi

    set_context_keywords "$proposed_name"
    FILE_COUNTERS=()
}

execute_organization_plan() {
    local category_dir="$BASE_PATH/$category"
    local subcategory_dir="$category_dir/$subcategory"
    local new_filepath="$subcategory_dir/$proposed_name"

    log_divider "DIRECTORY SETUP"
    log_info "Creating structure: $category/$subcategory/$proposed_name"

    # Create directory structure
    mkdir -p "$subcategory_dir"

    # Handle existing folder name conflicts
    if [[ -d "$new_filepath" ]]; then
        log_warn "Folder '$proposed_name' already exists, creating unique name"
        local counter=2
        local original_name="$proposed_name"
        while [[ -d "$subcategory_dir/$proposed_name" ]]; do
            proposed_name="${original_name} ${counter}"
            new_filepath="$subcategory_dir/$proposed_name"
            counter=$((counter + 1))
        done
        log_info "Using unique name: $proposed_name"
    fi

    # Move and setup folder
    setup_organized_folder "$new_filepath"

    # Organize files
    organize_files "$new_filepath"

    # Cleanup and finalize
    finalize_organization "$new_filepath"
}

setup_organized_folder() {
    local new_filepath="$1"
    local rename_file="$new_filepath/RENAMES.txt"

    log_divider "FOLDER RELOCATION"

    # Move folder and track rename
    mv "$INPUT_PATH" "$new_filepath"
    echo "$INPUT_PATH => $new_filepath" >> "$rename_file"

    # Open in Finder and create subfolders
    open "$new_filepath"
    touch "$rename_file"

    log_divider "STRUCTURE CREATION"
    local subfolders=("files" "images" "exports" "misc")
    for folder in "${subfolders[@]}"; do
        mkdir -p "$new_filepath/$folder"
    done

    # Create extension-based subdirectories in files folder
    log_info "Detecting file extensions for organized subdirectories"
    local extensions_list=$(collect_files_extensions "$new_filepath")

    if [[ -n "$extensions_list" ]]; then
        for ext in ${=extensions_list}; do
            local subdir=$(get_extension_subdirectory "$ext")
            if [[ -n "$subdir" ]]; then
                mkdir -p "$new_filepath/files/$subdir"
                log_info "Created subdirectory: files/$subdir"
            fi
        done
    fi

    # Move backup if it exists (after creating misc directory)
    if [[ -f "$backup_path" ]]; then
        mv "$backup_path" "$new_filepath/misc/"
        log_info "Backup moved to misc folder"
        echo "Backup: $backup_path => $new_filepath/misc/$(basename "$backup_path")" >> "$rename_file"
    fi
}

organize_files() {
    local new_filepath="$1"
    local rename_file="$new_filepath/RENAMES.txt"

    log_divider "FILE ORGANIZATION"
    log_info "Organizing files according to AI recommendations"

    # Keep special documentation files at root
    for file in "$new_filepath"/*; do
        if [[ -f "$file" ]]; then
            local basename=$(basename "$file")
            if is_special_doc_file "$basename"; then
                log_debug "Keeping special file at root: $basename"
                echo "Special file preserved: $basename => root/$basename" >> "$rename_file"
                continue
            fi
        fi
    done

    # Process AI file organization recommendations
    if echo "$ai_response" | jq -e '.fileOrganization[]' >/dev/null 2>&1; then
        log_info "Processing AI file organization recommendations"
        organize_with_ai_plan "$new_filepath" "$rename_file"
    else
        log_warn "No file organization data found, using fallback"
        organize_with_fallback "$new_filepath" "$rename_file"
    fi
}

organize_with_ai_plan() {
    local new_filepath="$1"
    local rename_file="$2"

    echo "$ai_response" | jq -r '.fileOrganization[] | @base64' 2>/dev/null | while read -r file_data; do
        if [[ -n "$file_data" ]]; then
            local file_info=$(echo "$file_data" | base64 -d 2>/dev/null)
            if [[ -n "$file_info" ]]; then
                local original_name=$(echo "$file_info" | jq -r '.originalFileName // empty')
                local proposed_name=$(echo "$file_info" | jq -r '.proposedFileName // empty')
                local target_subfolder=$(echo "$file_info" | jq -r '.targetSubfolder // "misc"')

                # Skip if parsing failed or special files
                if [[ -z "$original_name" || -z "$proposed_name" ]] || is_special_doc_file "$original_name"; then
                    continue
                fi

                move_file_to_target "$new_filepath" "$rename_file" "$original_name" "$proposed_name" "$target_subfolder"
            fi
        fi
    done
}

organize_with_fallback() {
    local new_filepath="$1"
    local rename_file="$2"

    for file in "$new_filepath"/*; do
        if [[ -f "$file" ]]; then
            local basename=$(basename "$file")

            # Skip special files
            if is_special_doc_file "$basename"; then
                continue
            fi

            local extension="${basename##*.}"
            local lowercase_ext=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
            local target_folder

            case "$lowercase_ext" in
                stl|f3d|3mf|step|stp|scad|blend|shapr) target_folder="files" ;;
                jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) target_folder="images" ;;
                gcode) target_folder="exports" ;;
                txt|pdf|html|htm|md|rtf|doc) continue ;; # Keep documentation at root
                *) target_folder="misc" ;;
            esac

            local destination_dir="$new_filepath/$target_folder"
            local destination_name="$(basename "$file")"
            local relative_path="$target_folder"

            if [[ "$target_folder" == "files" || "$target_folder" == "exports" || "$target_folder" == "misc" ]]; then
                local extension="${destination_name##*.}"
                if [[ "$destination_name" == "$extension" ]]; then
                    # Check for extension subdirectory
                    if [[ "$target_folder" == "files" && "$lowercase_ext" != "3mf" ]]; then
                        local extension_subdir=$(get_extension_subdirectory "$lowercase_ext")
                        if [[ -n "$extension_subdir" ]]; then
                            destination_dir="$destination_dir/$extension_subdir"
                            relative_path="$target_folder/$extension_subdir"
                        fi
                    fi
                    mv "$file" "$destination_dir/$destination_name" 2>/dev/null || true
                    echo "$(basename "$file") => $relative_path/$destination_name" >> "$rename_file"
                    continue
                fi
                local lowercase_extension="$(echo "$extension" | tr '[:upper:]' '[:lower:]')"
                local new_base="$(generate_semantic_basename "$destination_name" "$extension" "$target_folder")"
                new_base="$(sanitize_filename_component "$new_base")"
                destination_name="$new_base.$lowercase_extension"

                # Check for extension subdirectory
                if [[ "$target_folder" == "files" && "$lowercase_extension" != "3mf" ]]; then
                    local extension_subdir=$(get_extension_subdirectory "$lowercase_extension")
                    if [[ -n "$extension_subdir" ]]; then
                        destination_dir="$destination_dir/$extension_subdir"
                        relative_path="$target_folder/$extension_subdir"
                    fi
                fi
            fi

            mv "$file" "$destination_dir/$destination_name" 2>/dev/null || true
            echo "$(basename "$file") => $relative_path/$destination_name" >> "$rename_file"
        fi
    done
}

move_file_to_target() {
    local new_filepath="$1"
    local rename_file="$2"
    local original_name="$3"
    local proposed_name="$4"
    local target_subfolder="$5"

    # Find actual file (handle flattened names)
    local actual_file=""
    for file in "$new_filepath"/*; do
        local basename=$(basename "$file")
        if [[ "$basename" == "$original_name" || "$basename" == "$(basename "$new_filepath")_$original_name" ]]; then
            actual_file="$file"
            break
        fi
    done

    if [[ -n "$actual_file" && -f "$actual_file" ]]; then
        local target_dir="$new_filepath/$target_subfolder"
        [[ "$target_subfolder" == "root" ]] && target_dir="$new_filepath"

        # Ensure lowercase extension
        local extension="${proposed_name##*.}"
        local filename="${proposed_name%.*}"

        if [[ "$target_subfolder" == "files" || "$target_subfolder" == "exports" || "$target_subfolder" == "misc" ]]; then
            local original_base="$original_name"
            if [[ "$original_name" == *.* ]]; then
                original_base="${original_name%.*}"
            fi
            if needs_semantic_name "$original_base" "$filename"; then
                filename="$(generate_semantic_basename "$original_name" "$extension" "$target_subfolder")"
            fi
        fi

        filename="$(sanitize_filename_component "$filename")"
        local lowercase_extension="$(echo "$extension" | tr '[:upper:]' '[:lower:]')"

        # For files folder, check if we should use an extension-based subdirectory
        local extension_subdir=""
        local relative_path="$target_subfolder"
        if [[ "$target_subfolder" == "files" && "$lowercase_extension" != "3mf" ]]; then
            extension_subdir=$(get_extension_subdirectory "$lowercase_extension")
            if [[ -n "$extension_subdir" ]]; then
                target_dir="$target_dir/$extension_subdir"
                relative_path="$target_subfolder/$extension_subdir"
            fi
        fi

        local final_name="$filename.$lowercase_extension"
        local target_path="$target_dir/$final_name"

        # Handle conflicts
        if [[ -e "$target_path" ]]; then
            local counter=2
            local base_name="$filename"
            while [[ -e "$target_dir/${base_name}_${counter}.${lowercase_extension}" ]]; do
                counter=$((counter + 1))
            done
            final_name="${base_name}_${counter}.${lowercase_extension}"
        fi

        mv "$actual_file" "$target_dir/$final_name"
        echo "$(basename "$actual_file") => $relative_path/$final_name" >> "$rename_file"
    fi
}

finalize_organization() {
    local new_filepath="$1"

    log_divider "COMPLETION"
    log_info "Organization complete!"
    log_info "Organized folder: $new_filepath"

    # Show summary
    echo ""
    echo "ORGANIZATION SUMMARY:"
    echo "===================="
    echo "Original: $INPUT_PATH"
    echo "New location: $new_filepath"
    echo "Category: $category"
    echo "Subcategory: $subcategory"
    echo "Files organized: $(find "$new_filepath" -type f | wc -l | tr -d ' ')"
    echo "===================="
}

# Run main function
main
