#!/usr/bin/env zsh

set -a

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"

# Source logging utility if not already loaded
if [[ -z "${LOGGING_INITIALIZED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    source "$SCRIPT_DIR/../utilities/logging.sh"
    setup_script_logging
fi

# Only log initialization if this script is being run directly (not sourced)
if [[ "$0" == "${(%):-%N}" ]]; then
    log_info "Initializing OpenAI functions script"
fi

# Get tokens and keys from 1Password
***REMOVED***
OP_KEY_NAME="cli/openai-api"
API_KEY=$(op read -n "op://$OP_KEY_NAME/credential")

OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-https://api.openai.com/v1}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-5.1}"

if [[ -z "$API_KEY" ]]; then
    log_error "Failed to load OpenAI API key from 1Password item '$OP_KEY_NAME' (credential field)"
    exit 1
fi

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
    log_debug "Preparing request for OpenAI API chat completions"

    local request_body
    if ! request_body=$(printf '%s' "$1" | jq --arg model "$OPENAI_MODEL" '.model = (if .model then .model else $model end)'); then
        log_error "Failed to build OpenAI request body from payload"
        exit 1
    fi

    local endpoint="${OPENAI_API_BASE_URL%/}/chat/completions"
    log_debug "Sending request to $endpoint with model '$OPENAI_MODEL'"

    RESPONSE=$(curl -sS -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$request_body")

    # Check if the request was successful
    if [ $? -ne 0 ]; then
        log_error "Failed to send request to OpenAI API at $endpoint"
        exit -1
    fi

    log_debug "Received response from API, processing..."

    CLEANED_RESPONSE="$RESPONSE"

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

    # Normalize control characters that can break downstream JSON parsing
    CONTENT="$(printf '%s' "$CONTENT" | tr '\r\n' '  ')"
    CONTENT="${CONTENT//$'\t'/ }"

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

test-openai-connectivity() {
    local model="${1:-$OPENAI_MODEL}"
    local endpoint="${OPENAI_API_BASE_URL%/}/models/${model}"

    log_info "Testing OpenAI API connectivity for model '$model'"

    local tmp_response
    tmp_response=$(mktemp)

    local http_status
    if ! http_status=$(curl -sS -o "$tmp_response" -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        "$endpoint"); then
        log_error "Failed to reach OpenAI API during connectivity test"
        rm -f "$tmp_response"
        return 1
    fi

    local body
    body=$(cat "$tmp_response")
    rm -f "$tmp_response"

    if [[ "$http_status" == "200" ]]; then
        log_info "OpenAI connectivity check succeeded for model '$model'"
        if command -v jq >/dev/null 2>&1; then
            printf '%s' "$body" | jq '{id, owned_by, status: "available"}'
        else
            printf '%s\n' "$body"
        fi
        return 0
    fi

    local error_message
    error_message=$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null)

    if [[ -n "$error_message" ]]; then
        log_error "OpenAI connectivity check failed (HTTP $http_status): $error_message"
    else
        log_error "OpenAI connectivity check failed (HTTP $http_status). Response: $body"
    fi

    return 1
}
