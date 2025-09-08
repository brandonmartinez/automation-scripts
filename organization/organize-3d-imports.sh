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

# Check if file is a documentation file that should stay at root
is_special_doc_file() {
    local filename="$1"
    local lowercase_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')

    [[ "$lowercase_name" =~ ^(readme|license|summary)(\.|$) ]]
}

# Get file list as comma-separated string
get_file_list() {
    find "$1" -type f -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//'
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

    local user_message="# 3D Print File Organization Task

## CONTEXT
**Target Folder:** '$folder_name'
**Files to Organize:** $file_list

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
- Use Title Case with proper spacing
- Maintain technical precision while improving readability
- Keep file extensions lowercase

### 4. FILE ORGANIZATION
**Subfolders:**
- \"files/\" - 3D models (.stl, .f3d, .3mf, .step, .stp, .scad, .blend, .shapr)
- \"images/\" - Pictures (.jpg, .jpeg, .png, .heic, .heif, .bmp, .gif, .webp, .tif, .tiff)
- \"exports/\" - G-code (.gcode)
- \"misc/\" - Other non-documentation files
- \"root/\" - Documentation (.txt, .pdf, .html, .htm, .md, .rtf, .doc)

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

            mv "$file" "$new_filepath/$target_folder/" 2>/dev/null || true
            echo "$(basename "$file") => $target_folder/$(basename "$file")" >> "$rename_file"
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
        local final_name="$filename.$(echo "$extension" | tr '[:upper:]' '[:lower:]')"
        local target_path="$target_dir/$final_name"

        # Handle conflicts
        if [[ -e "$target_path" ]]; then
            local counter=2
            local base_name="$filename"
            local ext="$(echo "$extension" | tr '[:upper:]' '[:lower:]')"
            while [[ -e "$target_dir/${base_name}_${counter}.${ext}" ]]; do
                counter=$((counter + 1))
            done
            final_name="${base_name}_${counter}.${ext}"
        fi

        mv "$actual_file" "$target_dir/$final_name"
        echo "$(basename "$actual_file") => $target_subfolder/$final_name" >> "$rename_file"
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
