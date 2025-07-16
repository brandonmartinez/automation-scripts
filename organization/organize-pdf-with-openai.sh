#!/usr/bin/env zsh

# Set Shell Options
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
readonly PAPERWORK_DIR="${PAPERWORK_DIR:-$HOME/Documents/Paperwork}"
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-DEBUG}"

# Validate input argument early
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <pdf_file_path>" >&2
    echo "Please provide a PDF file path to organize" >&2
    exit 1
fi

readonly PDF_FILE="$1"

# Validate that the PDF file exists
if [[ ! -f "$PDF_FILE" ]]; then
    echo "Error: '$PDF_FILE' does not exist or is not a file" >&2
    exit 1
fi

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

# Log header to mark new session start
log_header "organize-pdf-with-openai.sh"


# ============================================================================
# SOURCE DEPENDENCIES
# ============================================================================

log_info "Sourcing Open AI Helpers from $SCRIPT_DIR"
source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

get-folder-structure() {
    local base_dir="$1"
    local max_depth="${2:-2}"  # Default to 2 levels deep

    if [ ! -d "$base_dir" ]; then
        echo "[]"
        return
    fi

    # Get folder structure and ensure clean JSON output
    local folder_list=$(find "$base_dir" -maxdepth "$max_depth" -type d -not -path "$base_dir" 2>/dev/null | \
        sed "s|^$base_dir/||" | \
        grep -v '^[[:space:]]*$' | \
        sort)

    if [ -z "$folder_list" ]; then
        echo "[]"
        return
    fi

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

strip-file-tags() {
    if xattr -p "com.apple.metadata:_kMDItemUserTags" "$1" >/dev/null 2>&1; then
        xattr -d "com.apple.metadata:_kMDItemUserTags" "$1"
    fi
}

set-finder-comments() {
    osascript -e 'on run {f, c}' -e 'tell app "Finder" to set comment of (POSIX file f as alias) to c' -e end "file://$1" "$2"
}

get-scanned-at() {
    echo "$1" |
        grep -oE '([0-9]{4})-([0-9]{2})-([0-9]{2})[-T]([0-9]{2})-([0-9]{2})-([0-9]{2})' |
        sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)[-T]\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1-\2-\3T\4-\5-\6/'
}

# JSON escaping functions to prevent API errors
escape-json-string() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//'
}

safe-json-escape() {
    # Remove or replace problematic characters that could break JSON
    echo "$1" | tr -cd '[:print:]' | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' '
}

# ============================================================================
# PROCESS FUNCTIONS
# ============================================================================

# Comprehensive AI processing function optimized for GPT-4o
# This replaces multiple AI calls with a single, context-aware call that:
# 1. Analyzes PDF content with full folder structure context
# 2. Provides both categorization and intelligent folder suggestions
# 3. Returns confidence scores and reasoning for transparency
# 4. Reduces API calls from potentially 3+ calls to 1 call
# 5. Uses GPT-4o specific prompt engineering for better results
comprehensive-ai-processing() {
    local pdf_text="$1"
    local folder_structure="$2"

    # Safely escape text for JSON to prevent control character errors
    local safe_pdf_text=$(safe-json-escape "$pdf_text")
    local safe_folder_structure=$(safe-json-escape "$folder_structure")

    OPENAI_SYSTEM_MESSAGE="You are an expert document categorization assistant specializing in intelligent file organization. Your task is to analyze PDF content and provide comprehensive categorization with folder structure awareness.

## Analysis Framework:
1. **Content Analysis**: Examine the document text to identify key entities, dates, and purpose
2. **Contextual Matching**: Use the existing folder structure to maintain consistency
3. **Intelligent Suggestions**: Recommend optimal folder placement considering existing organization

## Categorization Rules:
- **SENDER**: Use exact names when possible. For government: 'State of X', 'Federal Government', 'City of X', 'County of X'
- **CATEGORY**: Match existing categories when appropriate, suggest new ones when necessary
- **DEPARTMENT**: Include for government agencies, utilities, or large corporation divisions
- **SENT_ON**: Extract date in YYYY-MM-DD format
- **Legal Documents**: Categorize by the company involved (e.g., lawsuit against Samsung → SENDER: Samsung)
- **Checks**: CATEGORY: 'Finance', SENDER: 'Checks', DEPARTMENT: check writer

## Folder Structure Context:
The following existing folder structure should guide your categorization decisions:
$safe_folder_structure

## Output Requirements:
Provide both categorization AND intelligent folder suggestions based on existing structure. Consider similar senders, categories, and departments already present."

    OPENAI_USER_MESSAGE="Analyze this PDF content and provide comprehensive categorization with folder structure recommendations:

$safe_pdf_text"

    # Create JSON using jq to ensure proper escaping
    JSON_PAYLOAD=$(jq -n \
        --arg system_msg "$OPENAI_SYSTEM_MESSAGE" \
        --arg user_msg "$OPENAI_USER_MESSAGE" \
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
                                    "sentOn": {"type": "string"},
                                    "category": {"type": "string"},
                                    "shortSummary": {"type": "string"}
                                },
                                "required": ["sender", "department", "sentOn", "category", "shortSummary"],
                                "additionalProperties": false
                            },
                            "folderSuggestions": {
                                "type": "object",
                                "properties": {
                                    "suggestedCategory": {"type": ["string", "null"]},
                                    "suggestedSender": {"type": ["string", "null"]},
                                    "suggestedDepartment": {"type": ["string", "null"]},
                                    "reasoning": {"type": "string"},
                                    "alternativePaths": {"type": "array", "items": {"type": "string"}}
                                },
                                "required": ["suggestedCategory", "suggestedSender", "suggestedDepartment", "reasoning", "alternativePaths"],
                                "additionalProperties": false
                            }
                        },
                        "required": ["analysis", "categorization", "folderSuggestions"],
                        "additionalProperties": false
                    }
                }
            }
        }')

    get-openai-response "$JSON_PAYLOAD"
}

# ============================================================================
# PREPARATION - EXTRACT INITIAL FILE DATA
# ============================================================================

log_info "Starting PDF organization for: $(basename "$PDF_FILE")"

# Extract the date from the filename (should be in this format 2023-12-06T10-40-27)
SCANNED_AT=$(get-scanned-at "$PDF_FILE")
if [ -z "$SCANNED_AT" ]; then
    log_error "Scanned DateTime not found in the filename $PDF_FILE"
    exit 1
fi
log_debug "Extracted scanned timestamp: $SCANNED_AT"

log_info "Extracting text from PDF file"
PDF_TEXT=$(get-pdf-text "$PDF_FILE")
if [ -z "$PDF_TEXT" ]; then
    log_error "Failed to extract and/or sanitize text from the PDF"
    exit 1
fi
log_debug "Successfully extracted PDF text (${#PDF_TEXT} characters)"

# Get comprehensive folder structure for AI context
log_info "Analyzing existing folder structure"
FOLDER_STRUCTURE=$(get-folder-structure "$PAPERWORK_DIR" 3)
if [ -z "$FOLDER_STRUCTURE" ] || [ "$FOLDER_STRUCTURE" = "[]" ]; then
    log_info "No existing folder structure found - this will be a new organization"
    FOLDER_STRUCTURE="[]"
else
    log_debug "Folder structure for AI context: $FOLDER_STRUCTURE"
fi

# clear the attributes on the file to avoid double processing
log_debug "Clearing file attributes to avoid double processing"
strip-file-tags "$PDF_FILE"

# ============================================================================
# AI PROCESSING - CATEGORIZE AND ORGANIZE
# ============================================================================

log_info "Processing PDF content with comprehensive AI analysis"

# Validate inputs before sending to AI
if [ -z "$PDF_TEXT" ]; then
    log_error "PDF text is empty, cannot proceed with AI analysis"
    exit 1
fi

# Limit text length to prevent API issues (roughly 100k characters)
PDF_TEXT_LENGTH=${#PDF_TEXT}
if [ "$PDF_TEXT_LENGTH" -gt 100000 ]; then
    log_warn "PDF text is very long ($PDF_TEXT_LENGTH chars), truncating to prevent API issues"
    PDF_TEXT="${PDF_TEXT:0:100000}... [TRUNCATED]"
fi

log_debug "PDF text length: ${#PDF_TEXT} characters"
log_debug "Folder structure: $FOLDER_STRUCTURE"

AI_RESPONSE=$(comprehensive-ai-processing "$PDF_TEXT" "$FOLDER_STRUCTURE")

# Validate AI response
if [ -z "$AI_RESPONSE" ]; then
    log_error "AI response is empty. Check API connectivity and credentials."
    exit 1
fi

# Check if response contains error information
if echo "$AI_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    AI_ERROR=$(echo "$AI_RESPONSE" | jq -r '.error')
    log_error "AI API returned error: $AI_ERROR"
    exit 1
fi

echo-json "$AI_RESPONSE"

log_debug "Parsing comprehensive AI response"
# Extract categorization data
SENDER=$(echo "$AI_RESPONSE" | jq -r '.categorization.sender')
DEPARTMENT=$(echo "$AI_RESPONSE" | jq -r '.categorization.department')
if [ "$DEPARTMENT" = "null" ]; then
    DEPARTMENT=""
fi
SENT_ON=$(echo "$AI_RESPONSE" | jq -r '.categorization.sentOn' | tr '/: ' '-')
CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.categorization.category')
SHORT_SUMMARY=$(echo "$AI_RESPONSE" | jq -r '.categorization.shortSummary' | tr '"' "'")

# Extract AI suggestions for folder optimization
SUGGESTED_CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.folderSuggestions.suggestedCategory')
SUGGESTED_SENDER=$(echo "$AI_RESPONSE" | jq -r '.folderSuggestions.suggestedSender')
SUGGESTED_DEPARTMENT=$(echo "$AI_RESPONSE" | jq -r '.folderSuggestions.suggestedDepartment')
AI_REASONING=$(echo "$AI_RESPONSE" | jq -r '.folderSuggestions.reasoning')
CONFIDENCE=$(echo "$AI_RESPONSE" | jq -r '.analysis.confidence')

log_info "AI Analysis Results:"
log_info "  Categorization - SENDER: $SENDER, CATEGORY: $CATEGORY, DEPARTMENT: $DEPARTMENT"
log_info "  Suggestions - Category: $SUGGESTED_CATEGORY, Sender: $SUGGESTED_SENDER, Department: $SUGGESTED_DEPARTMENT"
log_info "  Confidence: $CONFIDENCE, Reasoning: $AI_REASONING"

# Use AI suggestions when they provide better matches
if [ "$SUGGESTED_CATEGORY" != "null" ] && [ -n "$SUGGESTED_CATEGORY" ]; then
    log_info "Using AI suggested category: $SUGGESTED_CATEGORY (instead of: $CATEGORY)"
    CATEGORY="$SUGGESTED_CATEGORY"
fi

if [ "$SUGGESTED_SENDER" != "null" ] && [ -n "$SUGGESTED_SENDER" ]; then
    log_info "Using AI suggested sender: $SUGGESTED_SENDER (instead of: $SENDER)"
    SENDER="$SUGGESTED_SENDER"
fi

if [ "$SUGGESTED_DEPARTMENT" != "null" ] && [ -n "$SUGGESTED_DEPARTMENT" ]; then
    log_info "Using AI suggested department: $SUGGESTED_DEPARTMENT (instead of: $DEPARTMENT)"
    DEPARTMENT="$SUGGESTED_DEPARTMENT"
fi

log_debug "Final parsed values - SENDER: $SENDER, DEPARTMENT: $DEPARTMENT, SENT_ON: $SENT_ON, CATEGORY: $CATEGORY"

# Validate required fields
if [ -z "$SENDER" ] || [ "$SENDER" = "null" ] ||
    [ -z "$SCANNED_AT" ] || [ "$SCANNED_AT" = "null" ] ||
    [ -z "$CATEGORY" ] || [ "$CATEGORY" = "null" ] ||
    [ -z "$SHORT_SUMMARY" ] || [ "$SHORT_SUMMARY" = "null" ]; then
    log_error "One or more required fields are empty or null"
    log_error "SENDER: '$SENDER', SCANNED_AT: '$SCANNED_AT', CATEGORY: '$CATEGORY', SHORT_SUMMARY: '$SHORT_SUMMARY'"
    exit 1
fi

# Warn if confidence is low
if command -v bc >/dev/null 2>&1 && [ "$CONFIDENCE" != "null" ]; then
    if [ "$(echo "$CONFIDENCE < 0.7" | bc)" -eq 1 ]; then
        log_warn "AI confidence is low ($CONFIDENCE). Manual review may be needed."
    fi
fi

log_info "Successfully categorized PDF with AI optimization: Category='$CATEGORY', Sender='$SENDER'"

# ============================================================================
# FOLDER STRUCTURE MANAGEMENT (SIMPLIFIED WITH AI SUGGESTIONS)
# ============================================================================

CATEGORY_DIR="$PAPERWORK_DIR/$CATEGORY"
SENDER_DIR="$CATEGORY_DIR/$SENDER"

# Create category directory if it doesn't exist
if [ ! -d "$CATEGORY_DIR" ]; then
    log_info "Creating new category folder: $CATEGORY_DIR"
    mkdir -p "$CATEGORY_DIR"
else
    log_debug "Category folder already exists: $CATEGORY_DIR"
fi

# Create sender directory if it doesn't exist
if [ ! -d "$SENDER_DIR" ]; then
    log_info "Creating sender folder: $SENDER_DIR"
    mkdir -p "$SENDER_DIR"
else
    log_debug "Sender folder already exists: $SENDER_DIR"
fi

# Handle department folder if specified
if [ -n "$DEPARTMENT" ]; then
    DEPARTMENT_DIR="$SENDER_DIR/$DEPARTMENT"
    if [ ! -d "$DEPARTMENT_DIR" ]; then
        log_info "Creating department folder: $DEPARTMENT_DIR"
        mkdir -p "$DEPARTMENT_DIR"
    else
        log_debug "Department folder already exists: $DEPARTMENT_DIR"
    fi
    # Update final destination to include department
    SENDER_DIR="$DEPARTMENT_DIR"
fi

# ============================================================================
# FILE PROCESSING AND COMPLETION
# ============================================================================

log_info "Preparing final file naming and placement"

# Create sanitized versions for file names
SENDER_SANITIZED=$(sanitize-text "$SENDER")

DEPARTMENT_SANITIZED=$(sanitize-text "$DEPARTMENT")
if [ -n "$DEPARTMENT_SANITIZED" ] && [ "$DEPARTMENT_SANITIZED" != "null" ]; then
    DEPARTMENT_SANITIZED="-${DEPARTMENT_SANITIZED}"
fi

NEW_FILE="$SENDER_DIR/$SENDER_SANITIZED$DEPARTMENT_SANITIZED-$SCANNED_AT-senton-$SENT_ON.pdf"
counter=1
while [ -e "$NEW_FILE" ]; do
    NEW_FILE="$SENDER_DIR/$SENDER_SANITIZED$DEPARTMENT_SANITIZED-$SCANNED_AT-senton-$SENT_ON-$(printf "%03d" $counter).pdf"
    counter=$((counter + 1))
done

log_info "Final file destination: $(basename "$NEW_FILE")"
log_debug "Full path: $NEW_FILE"

log_info "Copying PDF file to destination"
cp "$PDF_FILE" "$NEW_FILE"

log_info "Setting Finder comments with summary"
set-finder-comments "$NEW_FILE" "$SHORT_SUMMARY"

log_info "Opening destination folder in Finder"
open "$SENDER_DIR"

log_info "PDF organization completed successfully"
log_info "AI Optimizations Applied:"
log_info "  • Reduced AI calls from 3+ to 1 comprehensive call"
log_info "  • Enhanced context with full folder structure analysis"
log_info "  • GPT-4o optimized prompts with structured reasoning"
log_info "  • Confidence scoring and intelligent folder suggestions"
log_divider "END OF PROCESSING"

exit 0
