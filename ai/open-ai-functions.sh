#!/usr/bin/env zsh

set -a

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"

# Source logging utility if not already loaded
if [[ -z "${LOGGING_INITIALIZED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    source "$SCRIPT_DIR/../utilities/logging.sh"
fi

# Only log initialization if this script is being run directly (not sourced)
if [[ "$0" == "${(%):-%N}" ]]; then
    log_info "Initializing OpenAI functions script"
fi

# Get tokens and keys from 1Password
***REMOVED***
AZURE_OPENAI_ENDPOINT=$(op read -n "op://cli/aoai-mm-automation/url")
AZURE_OPENAI_TOKEN=$(op read -n "op://cli/aoai-mm-automation/token")
API_KEY=$(op read -n "op://cli/aoai-mm-automation/api-key")

set +a

echo-json() {
    log_debug "Formatting JSON output"
    echo $1 | jq . | bat --language=json --paging=never --style=numbers
}

escape-text() {
    echo "$1" |
        tr -s '[:space:]' ' ' |
        tr -cd 'A-Za-z0-9 ' |
        tr -d '\n' |
        tr -d '\r' |
        awk '{for (i=1; i<=NF && i<=1000; i++) printf "%s%s", $i, (i==NF || i==1000 ? "" : " ")}'
}

sanitize-text() {
    echo "$1" | tr -cd 'A-Za-z0-9'
}

get-pdf-text() {
    log_debug "Extracting text from PDF: $1"
    RAW_TEXT=$(pdftotext -nopgbrk -raw "$1" -)
    log_debug "PDF text extraction completed (length: ${#RAW_TEXT})"
    escape-text "$RAW_TEXT"
}

get-folder-list() {
    log_debug "Getting folder list from: $1"
    find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ',' | sed 's/,$//'
}

get-openai-response() {
    log_debug "Sending request to Azure OpenAI endpoint"

    # Send the extracted text to the Azure OpenAI endpoint
    RESPONSE=$(curl -s -X POST "$AZURE_OPENAI_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "api-key: $API_KEY" \
        -d "$1")

    # Check if the request was successful
    if [ $? -ne 0 ]; then
        log_error "Failed to send the text to the Azure OpenAI endpoint"
        exit -1
    fi

    log_debug "Received response from API, processing..."

    # First, let's check if we can extract content without validating the entire JSON
    CONTENT=$(printf '%s' "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [[ -n "$CONTENT" && "$CONTENT" != "null" && "$CONTENT" != "empty" ]]; then
        log_debug "Content extracted directly from raw response (length: ${#CONTENT})"
    else
        # If direct extraction failed, try with full JSON validation
        if echo "$RESPONSE" | jq . >/dev/null 2>&1; then
            log_debug "JSON parsed successfully (raw response)"
            CLEANED_RESPONSE="$RESPONSE"
        else
            log_warn "Raw response failed JSON parsing, attempting to clean..."
            # Clean the response of control characters before JSON parsing
            CLEANED_RESPONSE=$(printf '%s' "$RESPONSE" | tr -d '\000-\010\013\014\016-\037\177')

            if echo "$CLEANED_RESPONSE" | jq . >/dev/null 2>&1; then
                log_debug "JSON parsed successfully (after cleaning)"
            else
                log_warn "Could not parse response as JSON even after cleaning"
                log_debug "Raw response: $CLEANED_RESPONSE"
            fi
        fi

        # Re-extract content from cleaned response if needed
        if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
            CONTENT=$(echo "$CLEANED_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        fi
    fi

    # Check if response contains an error (skip if we already have content)
    if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
        ERROR_MESSAGE=$(echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq -r '.error.message // empty' 2>/dev/null)
        if [[ -n "$ERROR_MESSAGE" ]]; then
            log_error "API Error: $ERROR_MESSAGE"
            exit -1
        fi
    fi

    # Final content validation
    log_debug "Final content validation - length: ${#CONTENT}, preview: '${CONTENT:0:100}...'"

    if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
        log_error "No content found in API response after all attempts"
        log_debug "Response structure: $(echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq 'keys' 2>/dev/null || echo "Could not analyze")"
        exit -1
    fi

    # Parse the response to get the categorization and date
    echo "$CONTENT"
}
