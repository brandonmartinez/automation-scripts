#!/usr/bin/env zsh

# Set Shell Options
set -o errexit
set -o nounset
set -o pipefail

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
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-DEBUG}"
readonly MAX_PDF_TEXT_LENGTH=100000
readonly FOLDER_STRUCTURE_DEPTH=3
readonly OCR_SCRIPT="$SCRIPT_DIR/../media/pdf-ocr-text.sh"

# Global variables for processed data
declare -g PDF_FILE=""
declare -g SCANNED_AT=""
declare -g PDF_TEXT=""
declare -g FOLDER_STRUCTURE=""
declare -g AI_RESPONSE=""
declare -g MOVE_FILE=false
declare -g ADDITIONAL_CONTEXT=""

# ============================================================================
# INITIALIZATION AND VALIDATION
# ============================================================================

validate_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 [--move] <pdf_file_path>" >&2
        echo "Please provide a PDF file path to organize" >&2
        echo "Options:" >&2
        echo "  --move    Move the file instead of copying it" >&2
        exit 1
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
        --move)
            MOVE_FILE=true
            shift
            ;;
        --help | -h)
            echo "Usage: $0 [--move] <pdf_file_path>" >&2
            echo "Organizes PDF files using AI categorization" >&2
            echo "" >&2
            echo "Options:" >&2
            echo "  --move    Move the file instead of copying it" >&2
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
}

setup_environment() {
    # Ensure paperwork directory exists for logging
    if [[ ! -d "$PAPERWORK_DIR" ]]; then
        mkdir -p "$PAPERWORK_DIR"
    fi

    # Initialize logging utility
    export LOG_LEVEL=0
    export LOG_FD=2
    export LOG_FILE="$PAPERWORK_DIR/logfile.txt"
    source "$SCRIPT_DIR/../utilities/logging.sh"
    set_log_level "$LOG_LEVEL_NAME"

    log_info "Sourcing Open AI Helpers from $SCRIPT_DIR"
    if [[ ! -f "$SCRIPT_DIR/../ai/open-ai-functions.sh" ]]; then
        log_error "OpenAI functions not found at $SCRIPT_DIR/../ai/open-ai-functions.sh"
        exit 1
    fi
    source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

    # Log header to mark new session start
    log_header "organize-pdf-with-openai.sh"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

get_folder_structure() {
    local base_dir="$1"
    local max_depth="${2:-$FOLDER_STRUCTURE_DEPTH}"

    if [[ ! -d "$base_dir" ]]; then
        echo "[]"
        return
    fi

    # Get folder structure and ensure clean JSON output
    local folder_list
    folder_list=$(find "$base_dir" -maxdepth "$max_depth" -type d -not -path "$base_dir" 2>/dev/null |
        sed "s|^$base_dir/||" |
        grep -v '^[[:space:]]*$' |
        sort)

    if [[ -z "$folder_list" ]]; then
        echo "[]"
        return
    fi

    log_debug "Found folder structure: $folder_list"

    # Create clean JSON structure
    echo "$folder_list" | jq -R -s '
        split("\n") |
        map(select(length > 0)) |
        map(split("/")) |
        group_by(.[0]) |
        map({
            category: .[0][0],
            senders: (map(select(length > 1) | .[1]) | unique | select(length > 0)),
            departments: (map(select(length > 2) | {sender: .[1], department: .[2]}) | unique)
        })' 2>/dev/null || echo "[]"

}

strip_file_tags() {
    local file_path="$1"

    # Use tag command if available (handles all extended attributes automatically)
    if command -v tag >/dev/null 2>&1; then
        log_debug "Using 'tag' command to clear all tags and extended attributes"
        tag -r "*" "$file_path" 2>/dev/null || true
    else
        # Fallback: Manual extended attribute removal when tag command is not available
        log_debug "Using manual extended attribute removal (tag command not available)"
        local tag_attributes=(
            "com.apple.metadata:_kMDItemUserTags"
            "com.apple.metadata:kMDItemUserTags"
            "com.apple.FinderInfo"
            "com.apple.metadata:_kMDItemFinderComment"
        )

        for attr in "${tag_attributes[@]}"; do
            if xattr -p "$attr" "$file_path" >/dev/null 2>&1; then
                log_debug "Removing extended attribute: $attr"
                xattr -d "$attr" "$file_path" 2>/dev/null || true
            fi
        done

        # Additional AppleScript fallback for Finder labels
        log_debug "Using AppleScript fallback to clear Finder labels"
        osascript -e "
            try
                tell application \"Finder\"
                    set theFile to POSIX file \"$file_path\" as alias
                    set label index of theFile to 0
                    set comment of theFile to \"\"
                end tell
            on error
                -- Ignore errors if file is not accessible
            end try
        " 2>/dev/null || true
    fi
}

set_finder_comments() {
    local file_path="$1"
    local comment="$2"
    osascript -e 'on run {f, c}' -e 'tell app "Finder" to set comment of (POSIX file f as alias) to c' -e end "file://$file_path" "$comment"
}

extract_scanned_timestamp() {
    local filename="$1"

    # Try new format first: scan-YYYYMMDD (e.g., scan-20231206)
    local new_format_match
    new_format_match=$(echo "$filename" | grep -oE 'scan-([0-9]{8})' | sed 's/scan-//')

    if [[ -n "$new_format_match" ]]; then
        # Convert YYYYMMDD to YYYY-MM-DDTHH-MM-SS format (use 00-00-00 for time since we don't have it)
        local year="${new_format_match:0:4}"
        local month="${new_format_match:4:2}"
        local day="${new_format_match:6:2}"
        echo "${year}-${month}-${day}T00-00-00"
        return 0
    fi

    # Fallback to old format: YYYY-MM-DD[T]HH-MM-SS anywhere in filename
    local old_format_match
    old_format_match=$(echo "$filename" |
        grep -oE '([0-9]{4})-([0-9]{2})-([0-9]{2})[-T]([0-9]{2})-([0-9]{2})-([0-9]{2})' |
        sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)[-T]\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1-\2-\3T\4-\5-\6/')

    if [[ -n "$old_format_match" ]]; then
        echo "$old_format_match"
        return 0
    fi

    # If neither format is found, return empty (will trigger error in calling function)
    echo ""
    return 1
}

safe_json_escape() {
    # Remove or replace problematic characters that could break JSON
    echo "$1" | tr -cd '[:print:]' | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' '
}

validate_required_fields() {
    local sender="$1"
    local scanned_at="$2"
    local category="$3"
    local short_summary="$4"

    if [[ -z "$sender" || "$sender" == "null" ]] ||
        [[ -z "$scanned_at" || "$scanned_at" == "null" ]] ||
        [[ -z "$category" || "$category" == "null" ]] ||
        [[ -z "$short_summary" || "$short_summary" == "null" ]]; then
        log_error "One or more required fields are empty or null"
        log_error "SENDER: '$sender', SCANNED_AT: '$scanned_at', CATEGORY: '$category', SHORT_SUMMARY: '$short_summary'"
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
    structure=$(get_folder_structure "$PAPERWORK_DIR")

    if [[ -z "$structure" || "$structure" == "[]" ]]; then
        log_info "No existing folder structure found - this will be a new organization"
        echo "[]"
    else
        log_debug "Folder structure for AI context: $structure"
        echo "$structure"
    fi
}

# ============================================================================
# AI PROCESSING FUNCTIONS
# ============================================================================

# Comprehensive AI processing function optimized for GPT-4o
process_pdf_with_ai() {
    local pdf_text="$1"
    local folder_structure="$2"

    # Safely escape text for JSON to prevent control character errors
    local safe_pdf_text
    local safe_folder_structure
    safe_pdf_text=$(safe_json_escape "$pdf_text")
    safe_folder_structure=$(safe_json_escape "$folder_structure")

    local system_message
    system_message="You are an expert document categorization assistant specializing in intelligent file organization. Your task is to analyze PDF content and provide comprehensive categorization with folder structure awareness.

## Analysis Framework:
1. **Content Analysis**: Examine the document text to identify key entities, dates, and purpose
2. **Contextual Matching**: Use the existing folder structure to maintain consistency
3. **Intelligent Suggestions**: Recommend optimal folder placement considering existing organization

## Categorization Rules:
- **SENDER**: Use exact names when possible. For government: 'State of X', 'Federal Government', 'City of X', 'County of X'
- **CATEGORY**: Match existing categories when appropriate, suggest new ones when necessary
- **DEPARTMENT**: Only include for government organizations (federal, state, local agencies). Leave null for private companies, individuals, and non-government entities
- **ADDITIONAL_CONTEXT**: Use for key identifying details that aid in organization and searchability:
  • **Financial**: Check writer name, account numbers (last 4 digits), loan numbers, claim numbers
  • **Medical**: Doctor name, patient name, procedure type, appointment date
  • **Legal**: Case number, attorney name, court name, opposing party
  • **Insurance**: Policy number, claim number, agent name, coverage type
  • **Real Estate**: Property address, MLS number, agent name, transaction type
  • **Employment**: Employee ID, position title, department name, manager name
  • **Education**: Student name, course name, semester/year, institution
  • **Personal**: Contact name, event type, reference number, project name
- **SENT_ON**: Extract date in YYYY-MM-DD format
- **Legal Documents**: Categorize by the company involved (e.g., lawsuit against Samsung → SENDER: Samsung)
- **Checks**: CATEGORY: 'Finance', SENDER: 'Checks', DEPARTMENT: null, ADDITIONAL_CONTEXT: check writer name

## Folder Structure Context:
The following existing folder structure should guide your categorization decisions:
$safe_folder_structure

## Output Requirements:
Provide both categorization AND intelligent folder suggestions based on existing structure. Consider similar senders, categories, and departments already present."

    local user_message
    user_message="Analyze this PDF content and provide comprehensive categorization with folder structure recommendations:

$safe_pdf_text"

    # Create JSON using jq to ensure proper escaping
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
                                    "keyEntities": {"type": "array", "items": {"type": "string"}},
                                    "confidence": {"type": "number", "minimum": 0, "maximum": 1}
                                },
                                "required": ["documentType", "keyEntities", "confidence"],
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
                                    "shortSummary": {"type": "string"}
                                },
                                "required": ["sender", "department", "additionalContext", "sentOn", "category", "shortSummary"],
                                "additionalProperties": false
                            },
                            "folderSuggestions": {
                                "type": "object",
                                "properties": {
                                    "suggestedCategory": {"type": ["string", "null"]},
                                    "suggestedSender": {"type": ["string", "null"]},
                                    "suggestedDepartment": {"type": ["string", "null"]},
                                    "suggestedAdditionalContext": {"type": ["string", "null"]},
                                    "reasoning": {"type": "string"},
                                    "alternativePaths": {"type": "array", "items": {"type": "string"}}
                                },
                                "required": ["suggestedCategory", "suggestedSender", "suggestedDepartment", "suggestedAdditionalContext", "reasoning", "alternativePaths"],
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
    local sender department additional_context sent_on category short_summary
    sender=$(echo "$response" | jq -r '.categorization.sender')
    department=$(echo "$response" | jq -r '.categorization.department')
    additional_context=$(echo "$response" | jq -r '.categorization.additionalContext')
    sent_on=$(echo "$response" | jq -r '.categorization.sentOn' | tr '/: ' '-')
    category=$(echo "$response" | jq -r '.categorization.category')
    short_summary=$(echo "$response" | jq -r '.categorization.shortSummary' | tr '"' "'")

    # Handle null values
    if [[ "$department" == "null" ]]; then
        department=""
    fi
    if [[ "$additional_context" == "null" ]]; then
        additional_context=""
    fi

    # Set global variables for use in other functions
    declare -g SENDER="$sender"
    declare -g DEPARTMENT="$department"
    declare -g ADDITIONAL_CONTEXT="$additional_context"
    declare -g SENT_ON="$sent_on"
    declare -g CATEGORY="$category"
    declare -g SHORT_SUMMARY="$short_summary"
}

apply_ai_suggestions() {
    local response="$1"

    # Extract AI suggestions for folder optimization
    local suggested_category suggested_sender suggested_department suggested_additional_context ai_reasoning confidence
    suggested_category=$(echo "$response" | jq -r '.folderSuggestions.suggestedCategory')
    suggested_sender=$(echo "$response" | jq -r '.folderSuggestions.suggestedSender')
    suggested_department=$(echo "$response" | jq -r '.folderSuggestions.suggestedDepartment')
    suggested_additional_context=$(echo "$response" | jq -r '.folderSuggestions.suggestedAdditionalContext')
    ai_reasoning=$(echo "$response" | jq -r '.folderSuggestions.reasoning')
    confidence=$(echo "$response" | jq -r '.analysis.confidence')

    log_info "AI Analysis Results:"
    log_info "  Categorization - SENDER: $SENDER, CATEGORY: $CATEGORY, DEPARTMENT: $DEPARTMENT, ADDITIONAL_CONTEXT: $ADDITIONAL_CONTEXT"
    log_info "  Suggestions - Category: $suggested_category, Sender: $suggested_sender, Department: $suggested_department, Additional Context: $suggested_additional_context"
    log_info "  Confidence: $confidence, Reasoning: $ai_reasoning"

    # Use AI suggestions when they provide better matches
    if [[ "$suggested_category" != "null" && -n "$suggested_category" ]]; then
        log_info "Using AI suggested category: $suggested_category (instead of: $CATEGORY)"
        CATEGORY="$suggested_category"
    fi

    if [[ "$suggested_sender" != "null" && -n "$suggested_sender" ]]; then
        log_info "Using AI suggested sender: $suggested_sender (instead of: $SENDER)"
        SENDER="$suggested_sender"
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

    log_debug "Final parsed values - SENDER: $SENDER, DEPARTMENT: $DEPARTMENT, ADDITIONAL_CONTEXT: $ADDITIONAL_CONTEXT, SENT_ON: $SENT_ON, CATEGORY: $CATEGORY"
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

generate_unique_filename() {
    local destination_dir="$1"
    local sender_sanitized="$2"
    local department_sanitized="$3"
    local additional_context_sanitized="$4"
    local scanned_at="$5"
    local sent_on="$6"

    # macOS filename limit (255 characters)
    local max_filename_length=255

    # Format scan date to remove colons and T (YYYY-MM-DDTXX-XX-XX -> YYYYMMDD)
    local scan_date_formatted
    scan_date_formatted=$(echo "$scanned_at" | sed 's/T.*//' | tr -d '-')

    # Build filename components with fallback options
    local sender_part="$sender_sanitized$department_sanitized$additional_context_sanitized"
    local base_filename="${sent_on}_${sender_part}_scan-${scan_date_formatted}.pdf"

    # Check if filename is too long and create shorter versions if needed
    if [[ ${#base_filename} -gt $max_filename_length ]]; then
        log_warn "Filename too long (${#base_filename} chars), creating shorter version"

        # Fallback 1: Remove additional context
        if [[ -n "$additional_context_sanitized" ]]; then
            sender_part="$sender_sanitized$department_sanitized"
            base_filename="${sent_on}_${sender_part}_scan-${scan_date_formatted}.pdf"
            log_info "Removed additional context: new length ${#base_filename} chars"
        fi

        # Fallback 2: Remove department if still too long
        if [[ ${#base_filename} -gt $max_filename_length && -n "$department_sanitized" ]]; then
            sender_part="$sender_sanitized"
            base_filename="${sent_on}_${sender_part}_scan-${scan_date_formatted}.pdf"
            log_info "Removed department: new length ${#base_filename} chars"
        fi

        # Fallback 3: Truncate sender name if still too long
        if [[ ${#base_filename} -gt $max_filename_length ]]; then
            local fixed_part="${sent_on}__scan-${scan_date_formatted}.pdf"
            local available_length=$((max_filename_length - ${#fixed_part}))
            if [[ $available_length -gt 0 ]]; then
                sender_part="${sender_sanitized:0:$available_length}"
                base_filename="${sent_on}_${sender_part}_scan-${scan_date_formatted}.pdf"
                log_info "Truncated sender name: new length ${#base_filename} chars"
            else
                # Last resort: use minimal filename
                base_filename="${sent_on}_scan-${scan_date_formatted}.pdf"
                log_warn "Using minimal filename: ${base_filename}"
            fi
        fi
    fi

    local new_file="$destination_dir/$base_filename"

    # Handle duplicates with counter, ensuring we don't exceed length limit
    local counter=1
    while [[ -e "$new_file" ]]; do
        local counter_suffix="-$(printf "%03d" $counter)"
        local base_without_extension="${base_filename%.pdf}"
        local filename_with_counter="${base_without_extension}${counter_suffix}.pdf"

        # If counter makes filename too long, truncate the base part
        if [[ ${#filename_with_counter} -gt $max_filename_length ]]; then
            local extension=".pdf"
            local available_for_base=$((max_filename_length - ${#counter_suffix} - ${#extension}))
            base_without_extension="${base_without_extension:0:$available_for_base}"
            filename_with_counter="${base_without_extension}${counter_suffix}${extension}"
            log_info "Truncated base filename to accommodate counter: ${filename_with_counter}"
        fi

        new_file="$destination_dir/$filename_with_counter"
        counter=$((counter + 1))
    done

    echo "$new_file"
}

# ============================================================================
# FILE PROCESSING FUNCTIONS
# ============================================================================

prepare_initial_data() {
    log_info "Starting PDF organization for: $(basename "$PDF_FILE")"

    # Extract the date from the filename (should be in format 2023-12-06T10-40-27)
    SCANNED_AT=$(extract_scanned_timestamp "$PDF_FILE")
    if [[ -z "$SCANNED_AT" ]]; then
        log_error "Scanned DateTime not found in the filename $PDF_FILE"
        exit 1
    fi
    log_debug "Extracted scanned timestamp: $SCANNED_AT"

    # Extract text from PDF
    PDF_TEXT=$(extract_pdf_text "$PDF_FILE")
    log_debug "PDF text length: ${#PDF_TEXT} characters"

    # Get comprehensive folder structure for AI context
    FOLDER_STRUCTURE=$(prepare_folder_structure_context)

    # Clear file attributes to avoid double processing
    log_debug "Clearing file attributes to avoid double processing"
    strip_file_tags "$PDF_FILE"
}

process_with_ai() {
    log_info "Processing PDF content with comprehensive AI analysis"

    # Validate inputs before sending to AI
    if [[ -z "$PDF_TEXT" ]]; then
        log_error "PDF text is empty, cannot proceed with AI analysis"
        exit 1
    fi

    log_debug "PDF text length: ${#PDF_TEXT} characters"
    log_debug "Folder structure: $FOLDER_STRUCTURE"

    AI_RESPONSE=$(process_pdf_with_ai "$PDF_TEXT" "$FOLDER_STRUCTURE")
    validate_ai_response "$AI_RESPONSE"

    echo-json "$AI_RESPONSE"

    extract_categorization_data "$AI_RESPONSE"
    apply_ai_suggestions "$AI_RESPONSE"

    # Validate required fields
    if ! validate_required_fields "$SENDER" "$SCANNED_AT" "$CATEGORY" "$SHORT_SUMMARY"; then
        exit 1
    fi

    log_info "Successfully categorized PDF with AI optimization: Category='$CATEGORY', Sender='$SENDER'"
}

organize_and_move_file() {
    log_info "Preparing final file naming and placement"

    # Create folder structure and get destination directory
    local destination_dir
    destination_dir=$(create_folder_structure "$CATEGORY" "$SENDER" "$DEPARTMENT")

    # Create sanitized versions for file names
    local sender_sanitized department_sanitized additional_context_sanitized
    sender_sanitized=$(sanitize-text "$SENDER")
    department_sanitized=$(sanitize-text "$DEPARTMENT")
    additional_context_sanitized=$(sanitize-text "$ADDITIONAL_CONTEXT")

    if [[ -n "$department_sanitized" && "$department_sanitized" != "null" ]]; then
        department_sanitized="-${department_sanitized}"
    else
        department_sanitized=""
    fi

    if [[ -n "$additional_context_sanitized" && "$additional_context_sanitized" != "null" ]]; then
        additional_context_sanitized="-${additional_context_sanitized}"
    else
        additional_context_sanitized=""
    fi

    # Generate unique filename
    local new_file
    new_file=$(generate_unique_filename "$destination_dir" "$sender_sanitized" "$department_sanitized" "$additional_context_sanitized" "$SCANNED_AT" "$SENT_ON")

    log_info "Final file destination: $(basename "$new_file")"
    log_debug "Full path: $new_file"

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

    log_divider "END OF PROCESSING"
}

# Execute main function with all arguments
main "$@"
