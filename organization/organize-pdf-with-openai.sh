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

# ============================================================================
# PROCESS FUNCTIONS
# ============================================================================

initial-ai-processing() {
    OPENAI_SYSTEM_MESSAGE="You're an assistant that takes the text from PDF files and helps categorize for the purpose of file management and archiving the files. You will do your best to utilize a consistent response structure that includes the SENDER, SENT_ON date (YYYY-MM-DD formatted), a CATEGORY, a DEPARTMENT if possible, and a SHORT_SUMMARY of what the file is including the SENDER, SENT_ON date, and CATEGORY. For SENDER, if it's a government entity, use 'State of X' or 'Federal Government' or 'City of X' or 'X County'. For CATEGORY, ideally it should be in this list, but suggest something fitting if not: $2. If the document is from a government entity, service, or utility, the CATEGORY should be 'Government'; if from a school or university, the CATEGORY should be 'Education'. For DEPARTMENT, suggest one if it's a government department, agency, service, or utility, or if it's a large corporation's business unit. If you can't determine a value, leave it blank. If the content of the file appears to be related to a legal issue with or against a company, such as a lawsuit or a complaint, categorize it as if it was from that company for SENDER and choose the CATEGORY based on that SENDER (for example, if there is a lawsuit against Samsung, the SENDER should be Samsung and the CATEGORY should be retailers). If the document appears to be *only* a check (not a check attached to a full document), the CATEGORY should be 'Finance', the SENDER should be 'Checks', and the DEPARTMENT should be the person or organization the check is written from (not who the check is to nor which bank the check is routing from)."
    OPENAI_USER_MESSAGE="Please categorize the following text that came from a PDF:$1"

    # Create the JSON payload https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/structured-outputs?tabs=rest
    JSON_PAYLOAD=$(
        cat <<EOF
{
    "messages": [
        {
            "role": "system",
            "content": "$OPENAI_SYSTEM_MESSAGE"
        },
        {
            "role": "user",
            "content": "$OPENAI_USER_MESSAGE"
        }
    ],
    "response_format": {
        "type": "json_schema",
        "json_schema": {
            "name": "FileSystemCategorization",
            "strict": true,
            "schema": {
                "type": "object",
                "properties": {
                    "sender": {
                        "type": "string"
                    },
                    "department": {
                        "type": ["string", "null"]
                    },
                    "sentOn": {
                        "type": "string"
                    },
                    "category": {
                        "type": "string"
                    },
                    "shortSummary": {
                        "type": "string"
                    }
                },
                "required": [
                    "sender",
                    "department",
                    "sentOn",
                    "category",
                    "shortSummary"
                ],
                "additionalProperties": false
            }
        }
    }
}
EOF
    )

    get-openai-response "$JSON_PAYLOAD"
}

check-subfolders-with-ai() {
    OPENAI_SYSTEM_MESSAGE="You're an assistant that takes a list of folders and a proposed new folder name and suggests the best match based on the existing folders. If there is a perfect match, suggest that. If there is a close match, suggest that. If there is no match, return a null response."
    OPENAI_USER_MESSAGE="Please suggest the best match for the new folder '$2' in the from this list of existing folders:$1. Additionally, here's a description of a file that will be going in this folder to help determine the best match: $3"

    JSON_PAYLOAD=$(
        cat <<EOF
{
    "messages": [
        {
            "role": "system",
            "content": "$OPENAI_SYSTEM_MESSAGE"
        },
        {
            "role": "user",
            "content": "$OPENAI_USER_MESSAGE"
        }
    ],
    "response_format": {
        "type": "json_schema",
        "json_schema": {
            "name": "FolderCategorization",
            "strict": true,
            "schema": {
                "type": "object",
                "properties": {
                    "suggestion": {
                        "type": ["string", "null"]
                    }
                },
                "required": [
                    "suggestion"
                ],
                "additionalProperties": false
            }
        }
    }
}
EOF
    )

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

# Get a list of all top-level folders under $PAPERWORK_DIR
log_info "Getting list of existing category folders"
TOP_LEVEL_FOLDERS=$(get-folder-list "$PAPERWORK_DIR")
if [ -z "$TOP_LEVEL_FOLDERS" ]; then
    log_warn "No folders found in $PAPERWORK_DIR"
    exit 1
fi
log_debug "Found categories: $TOP_LEVEL_FOLDERS"

# clear the attributes on the file to avoid double processing
log_debug "Clearing file attributes to avoid double processing"
strip-file-tags "$PDF_FILE"

# ============================================================================
# AI PROCESSING - CATEGORIZE AND ORGANIZE
# ============================================================================

log_info "Processing PDF content with AI for categorization"
AI_RESPONSE=$(initial-ai-processing "$PDF_TEXT" "$TOP_LEVEL_FOLDERS")
echo-json "$AI_RESPONSE"

log_debug "Parsing AI response into environment variables"
SENDER=$(echo "$AI_RESPONSE" | jq -r '.sender')

DEPARTMENT=$(echo "$AI_RESPONSE" | jq -r '.department')
if [ "$DEPARTMENT" = "null" ]; then
    DEPARTMENT=""
fi

SENT_ON=$(echo "$AI_RESPONSE" | jq -r '.sentOn' | tr '/: ' '-')

CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.category')

SHORT_SUMMARY=$(echo "$AI_RESPONSE" | jq -r '.shortSummary' | tr '"' "'")

log_debug "Parsed values - SENDER: $SENDER, DEPARTMENT: $DEPARTMENT, SENT_ON: $SENT_ON, CATEGORY: $CATEGORY"

if [ -z "$SENDER" ] || [ "$SENDER" = "null" ] ||
    [ -z "$SCANNED_AT" ] || [ "$SCANNED_AT" = "null" ] ||
    [ -z "$CATEGORY" ] || [ "$CATEGORY" = "null" ] ||
    [ -z "$SHORT_SUMMARY" ] || [ "$SHORT_SUMMARY" = "null" ]; then
    log_error "One or more required fields are empty or null"
    log_error "SENDER: '$SENDER', SCANNED_AT: '$SCANNED_AT', CATEGORY: '$CATEGORY', SHORT_SUMMARY: '$SHORT_SUMMARY'"
    exit 1
fi

log_info "Successfully categorized PDF: Category='$CATEGORY', Sender='$SENDER'"

# ============================================================================
# FOLDER STRUCTURE MANAGEMENT
# ============================================================================

CATEGORY_DIR="$PAPERWORK_DIR/$CATEGORY"
SENDER_DIR="$CATEGORY_DIR/$SENDER"

# Check if there is already a category folder; if not, we can reduce processing since
# everything will be new
if [ ! -d "$CATEGORY_DIR" ]; then
    log_info "Creating new category folder: $CATEGORY_DIR"
    mkdir -p "$CATEGORY_DIR"
else
    # if there is already a sender directory, we can reduce processing as well and
    # assume that it's valid; if not, we'll check the subfolders
    log_debug "Category folder already exists: $CATEGORY_DIR"
    if [ ! -d "$SENDER_DIR" ]; then
        log_info "Sender folder doesn't exist, checking for best match: $SENDER_DIR"

        SENDER_SUBFOLDERS=$(get-folder-list "$CATEGORY_DIR")
        SENDER_AI_RESPONSE=$(check-subfolders-with-ai "$SENDER_SUBFOLDERS" "$SENDER" "$SHORT_SUMMARY")
        echo-json "$SENDER_AI_RESPONSE"

        SUGGESTED_FOLDER=$(echo "$SENDER_AI_RESPONSE" | jq -r '.suggestion')
        if [ -z "$SUGGESTED_FOLDER" ] || [ "$SUGGESTED_FOLDER" = "null" ]; then
            log_info "No suggestion provided; creating new sender folder: $SENDER_DIR"
            mkdir -p "$SENDER_DIR"
        else
            SENDER="$SUGGESTED_FOLDER"
            SENDER_DIR="$CATEGORY_DIR/$SENDER"
            log_info "Suggestion found, using existing folder: $SENDER_DIR"
        fi
    else
        log_debug "Sender folder already exists: $SENDER_DIR"
    fi

    # only check department if one was specified
    if [ -n "$DEPARTMENT" ]; then
        DEPARTMENT_DIR="$SENDER_DIR/$DEPARTMENT"
        log_debug "Department provided, checking if folder exists: $DEPARTMENT_DIR"

        # if the department dir doesn't already exist, check to see if there's a close match
        if [ ! -d "$DEPARTMENT_DIR" ]; then
            log_info "Department folder doesn't exist, checking for best match: $DEPARTMENT_DIR"
            DEPARTMENT_SUBFOLDERS=$(get-folder-list "$SENDER_DIR")
            DEPARTMENT_AI_RESPONSE=$(check-subfolders-with-ai "$DEPARTMENT_SUBFOLDERS" "$DEPARTMENT" "$SHORT_SUMMARY")
            echo-json "$DEPARTMENT_AI_RESPONSE"

            SUGGESTED_FOLDER=$(echo "$DEPARTMENT_AI_RESPONSE" | jq -r '.suggestion')
            if [ -z "$SUGGESTED_FOLDER" ] || [ "$SUGGESTED_FOLDER" = "null" ]; then
                log_info "No suggestion provided; creating new department folder: $DEPARTMENT_DIR"
                mkdir -p "$DEPARTMENT_DIR"
            else
                DEPARTMENT="$SUGGESTED_FOLDER"
                DEPARTMENT_DIR="$SENDER_DIR/$DEPARTMENT"
                log_info "Suggestion found, using existing folder: $DEPARTMENT_DIR"
            fi
        else
            log_debug "Department folder already exists: $DEPARTMENT_DIR"
        fi

        # update sender dir to include department
        SENDER_DIR="$DEPARTMENT_DIR"
    fi
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
log_divider "END OF PROCESSING"

exit 0
