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

# Set up base path and logging before any other imports
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
BASE_PATH="$HOME/Documents/3D Prints"
INPUT_PATH="$1"
NAME="$(basename "$INPUT_PATH")"

# Ensure base path exists for logging
if [[ ! -d "$BASE_PATH" ]]; then
    mkdir -p "$BASE_PATH"
fi

# Initialize logging utility with automatic file output
export LOG_LEVEL=0
export LOG_FD=2
export LOG_FILE="$BASE_PATH/logfile.txt"
source "$SCRIPT_DIR/../utilities/logging.sh"
set_log_level "${LOG_LEVEL_NAME:-INFO}"

# Set variables used in the script
##################################################
log_info "Starting 3D print file organization script"

# Validate input argument
if [[ $# -eq 0 ]]; then
    log_error "Usage: $0 <directory_path>"
    log_error "Please provide a directory path to organize"
    exit 1
fi

log_debug "Input path: $INPUT_PATH"

# Validate that the input path exists and is a directory
if [[ ! -d "$INPUT_PATH" ]]; then
    log_error "'$INPUT_PATH' does not exist or is not a directory"
    exit 1
fi
# Source Open AI Helpers
##################################################
log_debug "Sourcing Open AI Helpers from $SCRIPT_DIR"
source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

# Process Functions
##################################################
OPENAI_SYSTEM_MESSAGE="You are an expert 3D printing file organization specialist. Your role is to:

1. Analyze 3D printing project files and their context
2. Create logical, hierarchical folder structures for long-term organization
3. Generate descriptive, consistent file names that preserve important identifiers
4. Categorize files by type and purpose for optimal workflow

You have deep knowledge of:
- 3D printing file formats (.stl, .3mf, .step, .gcode, etc.)
- Common 3D printing brands, products, and part numbering systems
- File organization best practices for maker/engineering workflows
- Preserving technical identifiers while improving readability

Always prioritize consistency, discoverability, and preservation of important technical information."

get-file-list() {
    find "$1" -type f -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//'
}

extract-documentation-content() {
    local folder_path="$1"
    local content=""

    log_debug "Extracting documentation content from folder: $folder_path"

    # Find README files (case insensitive) - only check text-based extensions
    for readme_file in "$folder_path"/README* "$folder_path"/readme* "$folder_path"/Readme*; do
        if [[ -f "$readme_file" ]]; then
            local basename=$(basename "$readme_file")
            local lowercase_basename=$(echo "$basename" | tr '[:upper:]' '[:lower:]')
            local extension="${lowercase_basename##*.}"

            # Only process files with known text extensions or no extension
            if [[ "$lowercase_basename" =~ ^readme(\.|$) ]] && [[ "$extension" =~ ^(txt|md|rst||html|htm)$ || "$basename" == "$extension" ]]; then
                log_debug "Found README file: $basename"
                local readme_content=$(cat "$readme_file" 2>/dev/null | head -50)
                if [[ -n "$readme_content" ]]; then
                    content="$content\n\n=== README ($basename) ===\n$readme_content"
                fi
            fi
        fi
    done

    # Find PDF files and extract text using pdftotext if available
    if command -v pdftotext >/dev/null 2>&1; then
        for pdf_file in "$folder_path"/*.pdf "$folder_path"/*.PDF; do
            if [[ -f "$pdf_file" ]]; then
                local basename=$(basename "$pdf_file")
                log_debug "Found PDF file: $basename"
                local pdf_content=$(pdftotext "$pdf_file" - 2>/dev/null | head -100)
                if [[ -n "$pdf_content" ]]; then
                    content="$content\n\n=== PDF ($basename) ===\n$pdf_content"
                fi
            fi
        done
    else
        # Check if any PDF files exist and suggest installation
        local pdf_count=0
        for pdf_file in "$folder_path"/*.pdf "$folder_path"/*.PDF; do
            if [[ -f "$pdf_file" ]]; then
                pdf_count=$((pdf_count + 1))
            fi
        done

        if [[ $pdf_count -gt 0 ]]; then
            log_warn "Found $pdf_count PDF file(s) but pdftotext is not available"
            log_info "To extract PDF content for better organization, install poppler-utils: brew install poppler"

            for pdf_file in "$folder_path"/*.pdf "$folder_path"/*.PDF; do
                if [[ -f "$pdf_file" ]]; then
                    local basename=$(basename "$pdf_file")
                    content="$content\n\n=== PDF ($basename) ===\n[PDF file present but content extraction unavailable - install poppler-utils with 'brew install poppler' for text extraction]"
                fi
            done
        fi
    fi

    # Find other text-based documentation files with specific extensions
    for doc_file in "$folder_path"/*.txt "$folder_path"/*.md "$folder_path"/*.rtf "$folder_path"/*.TXT "$folder_path"/*.MD "$folder_path"/*.RTF; do
        if [[ -f "$doc_file" ]]; then
            local basename=$(basename "$doc_file")
            local lowercase_basename=$(echo "$basename" | tr '[:upper:]' '[:lower:]')

            # Skip README files (already processed above)
            if [[ ! "$lowercase_basename" =~ ^readme(\.|$) ]]; then
                log_debug "Found text documentation: $basename"

                # Handle RTF files with proper text extraction
                if [[ "$lowercase_basename" =~ \.rtf$ ]]; then
                    local doc_content=""
                    if command -v unrtf >/dev/null 2>&1; then
                        log_debug "Extracting RTF content using unrtf: $basename"
                        doc_content=$(unrtf --text "$doc_file" 2>/dev/null | head -50)
                    else
                        log_warn "Found RTF file but unrtf is not available: $basename"
                        log_info "To extract RTF content for better organization, install unrtf: brew install unrtf"
                        doc_content="[RTF file present but content extraction unavailable - install unrtf with 'brew install unrtf' for text extraction]"
                    fi
                else
                    # Handle regular text files
                    doc_content=$(cat "$doc_file" 2>/dev/null | head -50)
                fi

                if [[ -n "$doc_content" ]]; then
                    content="$content\n\n=== TEXT DOC ($basename) ===\n$doc_content"
                fi
            fi
        fi
    done

    if [[ -n "$content" ]]; then
        # Clean the content before returning it
        local clean_content=$(echo -e "$content" | tr -d '\000-\037\177' | tr -cd '[:print:][:space:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [[ -n "$clean_content" && "$clean_content" != " " ]]; then
            echo "$clean_content"
        fi
    fi
}

summarize-documentation() {
    local documentation_content="$1"

    log_debug "summarize-documentation called with content length: ${#documentation_content}"

    if [[ -z "$documentation_content" ]]; then
        log_debug "Documentation content is empty, returning early"
        echo ""
        return
    fi

    log_info "Summarizing documentation content for better organization context"

    # Clean the documentation content of control characters before processing
    local cleaned_content=$(printf '%s' "$documentation_content" | tr -d '\000-\037\177' | tr -cd '[:print:][:space:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    log_debug "After cleaning, content length: ${#cleaned_content}"
    log_debug "Cleaned content preview: ${cleaned_content:0:100}..."

    # If cleaning failed or resulted in empty content, skip documentation analysis
    if [[ -z "$cleaned_content" ]]; then
        log_warn "Documentation content could not be processed safely. Skipping summarization."
        echo ""
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

    log_debug "About to escape messages for JSON"

    # Test the escaping process step by step
    log_debug "Testing system message escaping..."
    local escaped_summary_system
    if ! escaped_summary_system=$(printf '%s' "$summary_system_message" | jq -R -s .); then
        log_error "Failed to escape system message"
        return
    fi
    log_debug "System message escaped successfully"

    log_debug "Testing user message escaping..."
    local escaped_summary_user
    if ! escaped_summary_user=$(printf '%s' "$summary_user_message" | jq -R -s .); then
        log_error "Failed to escape user message"
        log_debug "Problematic user message content: ${summary_user_message:0:500}..."
        log_debug "Hex dump of first 100 characters:"
        printf '%s' "$summary_user_message" | head -c 100 | hexdump -C >&2
        log_warn "Skipping documentation summarization due to character encoding issues"
        return
    fi
    log_debug "User message escaped successfully"

    log_debug "Creating JSON payload"
    # Create the JSON payload for summarization
    local summary_json_payload=$(jq -n \
        --argjson system_msg "$escaped_summary_system" \
        --argjson user_msg "$escaped_summary_user" \
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
            "temperature": 0.1
        }')
    log_debug "JSON payload created successfully"

    log_debug "Making API call"
    local summary_response=$(get-openai-response "$summary_json_payload")
    log_debug "API call completed, response length: ${#summary_response}"

    if [[ -n "$summary_response" && "$summary_response" != "null" ]]; then
        echo "$summary_response"
    else
        log_warn "Failed to summarize documentation - using original content"
        echo "$documentation_content"
    fi
}

get-folder-structure() {
    local base_path="$1"
    local structure=""

    log_debug "Getting folder structure from: $base_path"

    # Check if base path exists
    if [[ ! -d "$base_path" ]]; then
        log_warn "Base path does not exist: $base_path"
        return 1
    fi

    # Get top-level folders and their subfolders
    for category in "$base_path"/*; do
        if [[ -d "$category" ]]; then
            category_name=$(basename "$category")
            # Skip folders that start with underscore
            if [[ "$category_name" =~ ^_ ]]; then
                continue
            fi
            structure="$structure$category_name:\n"

            # Get subfolders for this category
            local subfolders=""
            for subfolder in "$category"/*; do
                if [[ -d "$subfolder" ]]; then
                    subfolder_name=$(basename "$subfolder")
                    # Skip subfolders that start with underscore
                    if [[ "$subfolder_name" =~ ^_ ]]; then
                        continue
                    fi
                    subfolders="$subfolders  - $subfolder_name\n"
                fi
            done

            if [[ -n "$subfolders" ]]; then
                structure="$structure$subfolders"
            else
                structure="$structure  - (no subfolders)\n"
            fi
            structure="$structure\n"
        fi
    done

    if [[ -z "$structure" ]]; then
        log_debug "No directories found in $base_path"
        return 1
    fi

    echo -e "$structure"
}

organize-all-files() {
    FOLDER_NAME="$1"
    FOLDER_STRUCTURE="$2"
    FULL_FILE_LIST="$3"
    DOCUMENTATION_CONTENT="$4"

    # Clean the documentation content of control characters before processing
    local CLEANED_DOCUMENTATION=""
    if [[ -n "$DOCUMENTATION_CONTENT" ]]; then
        CLEANED_DOCUMENTATION=$(printf '%s' "$DOCUMENTATION_CONTENT" | tr -d '\000-\037\177' | tr -cd '[:print:][:space:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # If cleaning failed or resulted in problematic content, skip documentation
        if [[ -z "$CLEANED_DOCUMENTATION" ]]; then
            echo "Warning: Documentation content could not be processed safely. Skipping documentation context."
            CLEANED_DOCUMENTATION=""
        fi
    fi

    OPENAI_USER_MESSAGE="# 3D Print File Organization Task

## CONTEXT
**Target Folder:** '$FOLDER_NAME'
**Files to Organize:** $FULL_FILE_LIST

## EXISTING STRUCTURE
$FOLDER_STRUCTURE"

    # Add documentation content if available
    if [[ -n "$CLEANED_DOCUMENTATION" ]]; then
        OPENAI_USER_MESSAGE="$OPENAI_USER_MESSAGE

## PROJECT CONTEXT
$CLEANED_DOCUMENTATION

**Important:** Use this context to make informed naming and categorization decisions. Pay special attention to model numbers, brands, and technical specifications."
    fi

    OPENAI_USER_MESSAGE="$OPENAI_USER_MESSAGE

## REQUIREMENTS

### 1. FOLDER NAMING
- Generate a descriptive, title-case name
- Preserve acronyms (PETG, PLA, etc.)
- Format: \"Brand - Product\" for branded items (e.g., \"Apple - iPhone 15 Case\")
- Remove redundant terms (\"3D files\", \"Model Files\")
- Keep descriptive terms (\"Kit\", \"Template\", \"Bracket\")

### 2. CATEGORIZATION HIERARCHY
- **Parent Category:** Select from existing structure or suggest new category
- **Sub-Category:** Choose appropriate subfolder maintaining consistency with existing patterns
- Consider: brands, product lines, functional groupings, or technical categories

### 3. FILE NAMING RULES
- **CRITICAL:** Preserve all model/part numbers from original names
- Use Title Case with proper spacing
- Examples:
  - \"iphone_15_case_v2.stl\" → \"iPhone 15 Case v2.stl\"
  - \"bearing_608zz.stl\" → \"Bearing 608ZZ.stl\"
  - \"M8x20_bolt.step\" → \"M8x20 Bolt.step\"
- Maintain technical precision while improving readability
- Keep file extensions lowercase
- No folder name prefixes in file names

### 4. FILE ORGANIZATION
**Subfolders:**
- \"files/\" - 3D models (.stl, .f3d, .3mf, .step, .stp, .scad, .blend, .shapr)
- \"images/\" - Pictures (.jpg, .jpeg, .png, .heic, .heif, .bmp, .gif, .webp, .tif, .tiff)
- \"exports/\" - G-code (.gcode)
- \"misc/\" - Other non-documentation files
- \"root/\" - Documentation (.txt, .pdf, .html, .htm, .md, .rtf, .doc)

## OUTPUT REQUIREMENTS
Provide a complete, consistent organization plan that maintains technical accuracy while improving discoverability."

    # Properly escape the message content for JSON, handling control characters
    ESCAPED_SYSTEM_MESSAGE=$(printf '%s' "$OPENAI_SYSTEM_MESSAGE" | jq -R -s .)
    ESCAPED_USER_MESSAGE=$(printf '%s' "$OPENAI_USER_MESSAGE" | jq -R -s .)

    # Create the JSON payload using jq to ensure proper escaping
    JSON_PAYLOAD=$(jq -n \
        --argjson system_msg "$ESCAPED_SYSTEM_MESSAGE" \
        --argjson user_msg "$ESCAPED_USER_MESSAGE" \
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
            "temperature": 0.2,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "ComprehensiveFileOrganization",
                    "strict": true,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "originalFolderName": {
                                "type": "string"
                            },
                            "proposedFolderName": {
                                "type": "string"
                            },
                            "parentCategory": {
                                "type": "string"
                            },
                            "subCategory": {
                                "type": "string"
                            },
                            "fileOrganization": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "originalFileName": {
                                            "type": "string"
                                        },
                                        "proposedFileName": {
                                            "type": "string"
                                        },
                                        "targetSubfolder": {
                                            "type": "string",
                                            "enum": ["files", "images", "exports", "misc", "root"]
                                        }
                                    },
                                    "required": [
                                        "originalFileName",
                                        "proposedFileName",
                                        "targetSubfolder"
                                    ],
                                    "additionalProperties": false
                                }
                            }
                        },
                        "required": [
                            "originalFolderName",
                            "proposedFolderName",
                            "parentCategory",
                            "subCategory",
                            "fileOrganization"
                        ],
                        "additionalProperties": false
                    }
                }
            }
        }')

    get-openai-response "$JSON_PAYLOAD"
}

# Start Processing
##################################################

# Get hierarchical folder structure instead of just top-level folders
log_debug "Getting folder structure from base path"
FOLDER_STRUCTURE=$(get-folder-structure "$BASE_PATH")
if [[ $? -ne 0 || -z "$FOLDER_STRUCTURE" ]]; then
    log_warn "Could not get folder structure from $BASE_PATH"
    log_info "This might be the first time organizing, or the path might not exist"
    FOLDER_STRUCTURE="No existing categories found. Please suggest appropriate categories for 3D print organization."
fi

log_info "Current folder structure:"
echo -e "$FOLDER_STRUCTURE"

# Create backup of original folder structure
log_divider "BACKUP CREATION"
log_info "Creating backup of original folder structure"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="${NAME}_backup_${TIMESTAMP}.zip"
BACKUP_PATH="$BASE_PATH/$BACKUP_NAME"

# Create zip backup of the original folder
cd "$(dirname "$INPUT_PATH")"
if zip -r "$BACKUP_PATH" "$(basename "$INPUT_PATH")" >/dev/null 2>&1; then
    log_info "Backup created successfully: $BACKUP_PATH"
else
    log_warn "Failed to create backup. Continuing with organization..."
fi

log_divider "FOLDER PREPARATION"
log_info "Flattening the original folder structure before AI processing"

# Remove OS-generated files that shouldn't be organized
log_debug "Removing OS-generated files..."
find "$INPUT_PATH" -name ".DS_Store" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "Thumbs.db" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "thumbs.db" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "desktop.ini" -delete 2>/dev/null || true
find "$INPUT_PATH" -name ".localized" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "._*" -delete 2>/dev/null || true

# Flatten any nested folder structure to give AI complete visibility of all files
log_debug "Flattening nested folder structures"
export INPUT_PATH
find "$INPUT_PATH" -mindepth 2 -type f -exec sh -c '
    for file; do
        base_file_name="$(basename "$file")"
        relative_path="${file#$INPUT_PATH/}"
        new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_$base_file_name"

        # Handle potential filename conflicts during flattening
        counter=1
        original_new_path="$new_path"
        while [ -e "$new_path" ]; do
            extension="${base_file_name##*.}"
            filename="${base_file_name%.*}"
            if [ "$extension" = "$base_file_name" ]; then
                # No extension
                new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_${filename}_${counter}"
            else
                new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_${filename}_${counter}.${extension}"
            fi
            counter=$((counter + 1))
        done

        echo "Flattening: $relative_path => $(basename "$new_path")"
        mv "$file" "$new_path"
    done
' sh {} +
find "$INPUT_PATH" -mindepth 1 -type d -empty -delete

# Get complete file list from the source folder AFTER flattening
FULL_FILE_LIST=$(get-file-list "$INPUT_PATH")
if [ -z "$FULL_FILE_LIST" ]; then
    log_error "No files found in $INPUT_PATH after flattening"
    exit 1
fi

log_divider "CONTENT ANALYSIS"
log_info "Analyzing folder '$NAME' with files: $FULL_FILE_LIST"
log_info "Extracting documentation content to improve organization decisions"

# Extract content from README and PDF files
log_debug "Calling extract-documentation-content for path: $INPUT_PATH"
RAW_DOCUMENTATION_CONTENT=$(extract-documentation-content "$INPUT_PATH")
log_debug "Raw documentation content length: ${#RAW_DOCUMENTATION_CONTENT}"
log_debug "Raw documentation content (first 200 chars): ${RAW_DOCUMENTATION_CONTENT:0:200}"

# Clean and validate documentation content before processing
CLEANED_RAW_CONTENT=""
if [[ -n "$RAW_DOCUMENTATION_CONTENT" ]]; then
    log_debug "Raw documentation content is not empty, proceeding to clean"
    # Clean the raw content and check if there's anything meaningful left
    CLEANED_RAW_CONTENT=$(printf '%s' "$RAW_DOCUMENTATION_CONTENT" | tr -d '\000-\037\177' | tr -cd '[:print:][:space:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    log_debug "Cleaned content length: ${#CLEANED_RAW_CONTENT}"
    log_debug "Cleaned content (first 200 chars): ${CLEANED_RAW_CONTENT:0:200}"
    log_debug "Hex dump of first 50 characters of cleaned content:"
    printf '%s' "$CLEANED_RAW_CONTENT" | head -c 50 | hexdump -C >&2
else
    log_debug "Raw documentation content is empty"
fi

# Summarize the documentation content to focus on essential information
if [[ -n "$CLEANED_RAW_CONTENT" && "$CLEANED_RAW_CONTENT" != " " ]]; then
    log_debug "Proceeding with documentation summarization"

    # Try documentation summarization with error handling
    if DOCUMENTATION_CONTENT=$(summarize-documentation "$CLEANED_RAW_CONTENT" 2>&1); then
        log_debug "Summarization successful, content length: ${#DOCUMENTATION_CONTENT}"
        if [[ -n "$DOCUMENTATION_CONTENT" ]]; then
            log_info "Documentation summarized for organization context"
            echo ""
            echo "DOCUMENTATION SUMMARY:"
            echo "====================="
            echo "$DOCUMENTATION_CONTENT"
            echo "====================="
            echo ""

            # Save summary to SUMMARY.txt file
            echo "$DOCUMENTATION_CONTENT" > "$INPUT_PATH/SUMMARY.txt"
            log_info "Documentation summary saved to SUMMARY.txt"
        else
            log_warn "Documentation content could not be summarized. Proceeding without documentation context."
            DOCUMENTATION_CONTENT=""
        fi
    else
        log_error "Documentation summarization failed with error:"
        echo "$DOCUMENTATION_CONTENT"
        log_warn "Proceeding without documentation context"
        DOCUMENTATION_CONTENT=""
    fi
else
    log_info "No documentation content found. Proceeding without documentation context."
    DOCUMENTATION_CONTENT=""
fi

log_info "Making comprehensive organization plan with AI"

# Make single AI call to organize everything
AI_RESPONSE=$(organize-all-files "$NAME" "$FOLDER_STRUCTURE" "$FULL_FILE_LIST" "$DOCUMENTATION_CONTENT")

# Debug: Check if we got a valid response
if [[ -z "$AI_RESPONSE" || "$AI_RESPONSE" == "null" ]]; then
    log_error "No response received from OpenAI API. Exiting."
    exit 1
fi

# Debug: Show raw response to help troubleshoot
log_debug "Raw AI Response:"
log_debug "$AI_RESPONSE"
log_debug "Response length: $(echo "$AI_RESPONSE" | wc -c) characters"

# Try to parse as JSON and check if it's valid
if ! echo "$AI_RESPONSE" | jq . >/dev/null 2>&1; then
    log_error "Invalid JSON response from OpenAI API:"
    log_error "$AI_RESPONSE"

    # Check if the response looks truncated
    if [[ "$AI_RESPONSE" == *"targetSub" ]] || [[ "$AI_RESPONSE" != *"}" ]]; then
        log_warn "Response appears to be truncated. This may be due to:"
        log_warn "1. Large number of files to organize"
        log_warn "2. API response size limits"
        log_warn "3. Network or connection issues"
        log_info "Consider organizing fewer files at once or checking your connection"
    fi
    exit 1
fi

# Comment out the echo-json call temporarily to avoid formatting issues
# echo-json "$AI_RESPONSE"

# Parse the comprehensive response
PROPOSED_NAME=$(echo "$AI_RESPONSE" | jq -r '.proposedFolderName // empty')
CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.parentCategory // empty')
SUBCATEGORY=$(echo "$AI_RESPONSE" | jq -r '.subCategory // empty')

# Check if we have the essential information even if JSON is truncated
if [[ -z "$PROPOSED_NAME" || "$PROPOSED_NAME" == "null" || -z "$CATEGORY" || "$CATEGORY" == "null" || -z "$SUBCATEGORY" || "$SUBCATEGORY" == "null" ]]; then
    log_error "AI response missing required information. Response may be truncated."

    # Try to extract what we can from a potentially truncated response
    if [[ "$AI_RESPONSE" == *'"proposedFolderName"'* ]]; then
        log_info "Attempting to extract partial information from truncated response..."

        # Try alternative parsing methods for truncated JSON
        PROPOSED_NAME=$(echo "$AI_RESPONSE" | grep -o '"proposedFolderName":"[^"]*"' | cut -d'"' -f4 | head -1)
        CATEGORY=$(echo "$AI_RESPONSE" | grep -o '"parentCategory":"[^"]*"' | cut -d'"' -f4 | head -1)
        SUBCATEGORY=$(echo "$AI_RESPONSE" | grep -o '"subCategory":"[^"]*"' | cut -d'"' -f4 | head -1)

        log_debug "Extracted - Name: '$PROPOSED_NAME', Category: '$CATEGORY', Subcategory: '$SUBCATEGORY'"

        if [[ -n "$PROPOSED_NAME" && -n "$CATEGORY" && -n "$SUBCATEGORY" ]]; then
            log_warn "Found essential folder organization information. Continuing with basic organization..."
            log_warn "File-level organization may be incomplete due to truncated response."
        else
            log_error "Could not extract essential information. Exiting."
            exit 1
        fi
    else
        exit 1
    fi
fi

CATEGORY_DIR="$BASE_PATH/$CATEGORY"
SUBCATEGORY_DIR="$CATEGORY_DIR/$SUBCATEGORY"
NEW_FILEPATH="$SUBCATEGORY_DIR/$PROPOSED_NAME"
RENAME_FILE="$NEW_FILEPATH/RENAMES.txt"

log_divider "DIRECTORY SETUP"
log_info "Creating directory structure:"
log_info "Category: $CATEGORY"
log_info "Subcategory: $SUBCATEGORY"
log_info "Final path: $NEW_FILEPATH"

# Create directory structure
if [ ! -d "$CATEGORY_DIR" ]; then
    log_info "Creating category folder: $CATEGORY"
    mkdir -p "$CATEGORY_DIR"
fi

if [ ! -d "$SUBCATEGORY_DIR" ]; then
    log_info "Creating subcategory folder: $SUBCATEGORY"
    mkdir -p "$SUBCATEGORY_DIR"
fi

# TODO: check if there's already a folder called this, if so ask for another name until it doesn't exist
if [[ -d "$NEW_FILEPATH" ]]; then
    log_warn "Folder '$PROPOSED_NAME' already exists in $SUBCATEGORY_DIR"
    COUNTER=2
    ORIGINAL_PROPOSED_NAME="$PROPOSED_NAME"
    while [[ -d "$SUBCATEGORY_DIR/$PROPOSED_NAME" ]]; do
        PROPOSED_NAME="${ORIGINAL_PROPOSED_NAME} ${COUNTER}"
        NEW_FILEPATH="$SUBCATEGORY_DIR/$PROPOSED_NAME"
        COUNTER=$((COUNTER + 1))
    done
    log_info "Using unique name: $PROPOSED_NAME"
    RENAME_FILE="$NEW_FILEPATH/RENAMES.txt"
fi

log_divider "FOLDER RELOCATION"
log_info "Moving $INPUT_PATH to $NEW_FILEPATH"

mv "$INPUT_PATH" "$NEW_FILEPATH"
echo "$INPUT_PATH => $NEW_FILEPATH" >> "$RENAME_FILE"

log_divider "BACKUP MANAGEMENT"
log_info "Moving backup file to organized folder"

# Move the backup zip file to the new organized location
if [[ -f "$BACKUP_PATH" ]]; then
    mv "$BACKUP_PATH" "$NEW_FILEPATH/"
    log_info "Backup moved to: $NEW_FILEPATH/$(basename "$BACKUP_PATH")"
    echo "Backup: $BACKUP_PATH => $NEW_FILEPATH/$(basename "$BACKUP_PATH")" >> "$RENAME_FILE"
else
    log_warn "Backup file not found at $BACKUP_PATH"
fi

log_divider "WORKSPACE SETUP"
log_info "Opening $NEW_FILEPATH in Finder"
open "$NEW_FILEPATH"
touch "$RENAME_FILE"

log_divider "STRUCTURE CREATION"
log_info "Creating organized folder structure"

FILES_FOLDER="$NEW_FILEPATH/files"
IMAGES_FOLDER="$NEW_FILEPATH/images"
EXPORTS_FOLDER="$NEW_FILEPATH/exports"
MISC_FOLDER="$NEW_FILEPATH/misc"

# Remove any existing conflicting folders first
if [[ -d "$FILES_FOLDER" ]]; then
    log_warn "files folder already exists, merging contents..."
fi
if [[ -d "$IMAGES_FOLDER" ]]; then
    log_warn "images folder already exists, merging contents..."
fi
if [[ -d "$EXPORTS_FOLDER" ]]; then
    log_warn "exports folder already exists, merging contents..."
fi
if [[ -d "$MISC_FOLDER" ]]; then
    log_warn "misc folder already exists, merging contents..."
fi

mkdir -p "$FILES_FOLDER"
mkdir -p "$IMAGES_FOLDER"
mkdir -p "$EXPORTS_FOLDER"
mkdir -p "$MISC_FOLDER"

log_divider "FILE ORGANIZATION"
log_info "Organizing and renaming files according to AI plan"

# First, handle special files (README, LICENSE, SUMMARY) that should stay at root with original names
for file in "$NEW_FILEPATH"/*; do
    if [[ -f "$file" ]]; then
        BASENAME=$(basename "$file")
        LOWERCASE_BASENAME=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')

        # Check if it's a README, LICENSE, or SUMMARY file (case insensitive)
        if [[ "$LOWERCASE_BASENAME" =~ ^readme(\.|$) || "$LOWERCASE_BASENAME" =~ ^license(\.|$) || "$LOWERCASE_BASENAME" =~ ^summary(\.|$) ]]; then
            log_debug "Keeping special file at root: $BASENAME"
            echo "Special file preserved: $BASENAME => root/$BASENAME" >> "$RENAME_FILE"
            # File stays where it is, no moving needed
            continue
        fi
    fi
done

# Process each file according to AI recommendations
# Check if we have file organization data before attempting to process
if echo "$AI_RESPONSE" | jq -e '.fileOrganization[]' >/dev/null 2>&1; then
    log_info "Processing AI file organization recommendations..."
    echo "$AI_RESPONSE" | jq -r '.fileOrganization[] | @base64' 2>/dev/null | while IFS= read -r file_data; do
        if [[ -n "$file_data" ]]; then
            FILE_INFO=$(echo "$file_data" | base64 -d 2>/dev/null)
            if [[ -n "$FILE_INFO" ]]; then
                ORIGINAL_NAME=$(echo "$FILE_INFO" | jq -r '.originalFileName // empty' 2>/dev/null)
                PROPOSED_NAME=$(echo "$FILE_INFO" | jq -r '.proposedFileName // empty' 2>/dev/null)
                TARGET_SUBFOLDER=$(echo "$FILE_INFO" | jq -r '.targetSubfolder // "misc"' 2>/dev/null)

                # Skip if we couldn't parse the file info
                if [[ -z "$ORIGINAL_NAME" || -z "$PROPOSED_NAME" ]]; then
                    log_warn "Skipping malformed file organization entry"
                    continue
                fi

    # Skip README, LICENSE, and SUMMARY files - they stay at root with original names
    LOWERCASE_ORIGINAL=$(echo "$ORIGINAL_NAME" | tr '[:upper:]' '[:lower:]')
    if [[ "$LOWERCASE_ORIGINAL" =~ ^readme(\.|$) || "$LOWERCASE_ORIGINAL" =~ ^license(\.|$) || "$LOWERCASE_ORIGINAL" =~ ^summary(\.|$) ]]; then
        continue
    fi

    # Find the actual file (handle case sensitivity and flattened names)
    ACTUAL_FILE=""
    for file in "$NEW_FILEPATH"/*; do
        BASENAME=$(basename "$file")
        if [[ "$BASENAME" == "$ORIGINAL_NAME" || "$BASENAME" == "$(basename "$NEW_FILEPATH")_$ORIGINAL_NAME" ]]; then
            ACTUAL_FILE="$file"
            break
        fi
    done

    if [[ -n "$ACTUAL_FILE" && -f "$ACTUAL_FILE" ]]; then
        # Determine target directory
        case "$TARGET_SUBFOLDER" in
            "files")
                TARGET_DIR="$FILES_FOLDER"
                ;;
            "images")
                TARGET_DIR="$IMAGES_FOLDER"
                ;;
            "exports")
                TARGET_DIR="$EXPORTS_FOLDER"
                ;;
            "misc")
                TARGET_DIR="$MISC_FOLDER"
                ;;
            "root")
                TARGET_DIR="$NEW_FILEPATH"
                ;;
            *)
                TARGET_DIR="$MISC_FOLDER"
                ;;
        esac

        # Convert extension to lowercase
        EXTENSION="${PROPOSED_NAME##*.}"
        FILENAME="${PROPOSED_NAME%.*}"
        LOWERCASE_EXTENSION=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')
        FINAL_NAME="$FILENAME.$LOWERCASE_EXTENSION"

        TARGET_PATH="$TARGET_DIR/$FINAL_NAME"

        # Check if target file already exists
        if [[ ! -e "$TARGET_PATH" ]]; then
            log_debug "Moving and renaming: $(basename "$ACTUAL_FILE") -> $TARGET_SUBFOLDER/$FINAL_NAME"
            echo "$(basename "$ACTUAL_FILE") => $TARGET_SUBFOLDER/$FINAL_NAME" >> "$RENAME_FILE"
            mv "$ACTUAL_FILE" "$TARGET_PATH"
        else
            log_warn "Target file $FINAL_NAME already exists in $TARGET_SUBFOLDER"
            # Create a unique name by adding a counter
            COUNTER=2
            ORIGINAL_FINAL_NAME="$FINAL_NAME"
            EXTENSION="${FINAL_NAME##*.}"
            FILENAME="${FINAL_NAME%.*}"
            while [[ -e "$TARGET_DIR/${FILENAME}_${COUNTER}.${EXTENSION}" ]]; do
                COUNTER=$((COUNTER + 1))
            done
            UNIQUE_NAME="${FILENAME}_${COUNTER}.${EXTENSION}"
            log_info "Using unique name: $UNIQUE_NAME"
            echo "$(basename "$ACTUAL_FILE") => $TARGET_SUBFOLDER/$UNIQUE_NAME" >> "$RENAME_FILE"
            mv "$ACTUAL_FILE" "$TARGET_DIR/$UNIQUE_NAME"
        fi
        else
            log_warn "Could not find file $ORIGINAL_NAME"
        fi
            fi
        fi
    done
else
    log_warn "No file organization data found in AI response. Using fallback organization..."
fi

log_divider "CLEANUP PROCESSING"
log_info "Moving any remaining unprocessed files"

# Handle any files that weren't processed by the AI (safety net)
for file in "$NEW_FILEPATH"/*; do
    if [[ -f "$file" ]]; then
        BASENAME=$(basename "$file")
        LOWERCASE_BASENAME=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')

        # Skip README, LICENSE, and SUMMARY files - they stay at root
        if [[ "$LOWERCASE_BASENAME" =~ ^readme(\.|$) || "$LOWERCASE_BASENAME" =~ ^license(\.|$) || "$LOWERCASE_BASENAME" =~ ^summary(\.|$) ]]; then
            continue
        fi

        EXTENSION="${BASENAME##*.}"
        LOWERCASE_EXT=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')

        case "$LOWERCASE_EXT" in
            stl|f3d|3mf|step|stp|scad|blend|shapr)
                mv "$file" "$FILES_FOLDER/" 2>/dev/null || true
                ;;
            jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff)
                mv "$file" "$IMAGES_FOLDER/" 2>/dev/null || true
                ;;
            gcode)
                mv "$file" "$EXPORTS_FOLDER/" 2>/dev/null || true
                ;;
            txt|pdf|html|htm|md|rtf|doc)
                # Keep documentation files in root
                ;;
            *)
                mv "$file" "$MISC_FOLDER/" 2>/dev/null || true
                ;;
        esac
    fi
done

log_divider "COMPLETION"
log_info "Organization complete!"

exit 0
