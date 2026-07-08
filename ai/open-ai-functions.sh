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

ensure_openai_key() {
    [[ -n "${OPENAI_API_KEY:-}" ]] && return 0

    # Some headless contexts may not have $USER; derive it
    local user_name="${USER:-}"
    [[ -z "$user_name" ]] && user_name=$(id -un 2>/dev/null || printf '')
    [[ -z "$user_name" ]] && user_name=""

    local key_name="${OP_KEY_NAME:-cli/openai-api}"

    # Try op first
    if command -v op >/dev/null 2>&1; then
        # Load service token from Keychain if not already present
        if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && command -v security >/dev/null 2>&1 && [[ -n "$user_name" ]]; then
            if OP_SERVICE_ACCOUNT_TOKEN=$(security find-generic-password -w -a "$user_name" -s "op-service-token-openai-api" 2>/dev/null); then
                export OP_SERVICE_ACCOUNT_TOKEN
            fi
        fi

        if OPENAI_API_KEY=$(op read "op://$key_name/credential" 2>/dev/null); then
            export OPENAI_API_KEY
            return 0
        fi
        log_warn "op read failed; trying Keychain fallback for OPENAI_API_KEY"
    else
        log_warn "op CLI not found; trying Keychain fallback for OPENAI_API_KEY"
    fi

    # Fallback: macOS Keychain item named openai-api-key (user-scoped)
    if command -v security >/dev/null 2>&1 && [[ -n "$user_name" ]]; then
        if OPENAI_API_KEY=$(security find-generic-password -w -a "$user_name" -s "openai-api-key" 2>/dev/null); then
            export OPENAI_API_KEY
            return 0
        fi
    fi

    return 1
}

# Provider selection: "openai" (default, OpenAI-compatible HTTP API) or
# "copilot" (headless Copilot CLI, which bills zero premium requests on gpt-5.x).
AI_PROVIDER="${AI_PROVIDER:-openai}"

# OpenAI credentials are only required when the OpenAI provider is active, so a
# copilot-only run does not depend on OpenAI keys being present.
if [[ "$AI_PROVIDER" != "copilot" ]]; then
    if ! ensure_openai_key; then
        log_error "OPENAI_API_KEY is not set"
        exit 1
    fi
fi

OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-https://api.openai.com/v1}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-5.4}"
# Reasoning effort for GPT-5.x models (minimal|low|medium|high). Set empty to omit.
OPENAI_REASONING_EFFORT="${OPENAI_REASONING_EFFORT:-low}"

# Copilot headless provider configuration.
COPILOT_MODEL="${COPILOT_MODEL:-gpt-5.4}"
COPILOT_CONFIG_HOME="${COPILOT_HOME:-$HOME/.copilot}"

set +a

echo-json() {
    log_debug "Formatting JSON output"
    echo $1 | jq . | bat --language=json --paging=never --style=numbers
}

escape-text() {
    # Normalize whitespace and strip control characters while preserving
    # punctuation, symbols, and UTF-8 so the model receives faithful document
    # text (dates, amounts, account numbers, sender names, etc.). Downstream
    # callers bound the length; jq --arg handles JSON escaping.
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        tr -d '\000-\010\013\014\016-\037\177' |
        tr -s ' '
}

sanitize-text() {
    # Filesystem-safe filename component: keep letters, numbers, spaces,
    # hyphens and ordinary punctuation; drop path separators and other
    # illegal characters; collapse whitespace and trim edges.
    printf '%s' "$1" |
        tr -d '\000-\037\177' |
        sed -E 's#[/\\:*?"<>|]# #g' |
        tr -s ' ' |
        sed -E 's/^[[:space:].]+//; s/[[:space:].]+$//'
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
        return 1
    fi

    local endpoint="${OPENAI_API_BASE_URL%/}/chat/completions"
    local request_model
    request_model=$(printf '%s' "$request_body" | jq -r '.model // empty' 2>/dev/null)
    if [[ -z "$request_model" || "$request_model" == "null" ]]; then
        request_model="$OPENAI_MODEL"
        # ensure model is set in the body if it was missing
        request_body=$(printf '%s' "$request_body" | jq --arg model "$request_model" '.model = $model')
    fi

    # Inject reasoning effort for GPT-5.x models unless already set or disabled.
    if [[ -n "${OPENAI_REASONING_EFFORT:-}" ]]; then
        request_body=$(printf '%s' "$request_body" | jq --arg effort "$OPENAI_REASONING_EFFORT" '.reasoning_effort = (if .reasoning_effort then .reasoning_effort else $effort end)')
    fi

    log_debug "Sending request to $endpoint with model '$request_model'"

    local req_file
    req_file=$(mktemp)
    printf '%s' "$request_body" >"$req_file"

    local attempt=0
    local max_attempts=3
    local sleep_base=2
    local curl_status=0
    local RESPONSE=""

    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))

        RESPONSE=$(curl -sS --max-time 60 -X POST "$endpoint" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -d @"$req_file")
        curl_status=$?

        if [ $curl_status -eq 0 ]; then
            break
        fi

        log_warn "OpenAI request failed (attempt $attempt/$max_attempts); retrying after backoff"
        local sleep_time=$((sleep_base ** attempt))
        sleep "$sleep_time"
    done

    rm -f "$req_file"

    # Check if the request was successful
    if [ $curl_status -ne 0 ]; then
        log_error "Failed to send request to OpenAI API at $endpoint after $max_attempts attempts"
        return 1
    fi

    log_debug "Received response from API, processing..."

    CLEANED_RESPONSE="$RESPONSE"

    # First, let's check if we can extract content without validating the entire JSON
    CONTENT_RAW=$(printf '%s' "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [[ -n "$CONTENT_RAW" && "$CONTENT_RAW" != "null" && "$CONTENT_RAW" != "empty" ]]; then
        log_debug "Content extracted directly from raw response (length: ${#CONTENT_RAW})"
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
        if [[ -z "$CONTENT_RAW" || "$CONTENT_RAW" == "null" || "$CONTENT_RAW" == "empty" ]]; then
            CONTENT_RAW=$(echo "$CLEANED_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        fi
    fi

    # Check if response contains an error (skip if we already have content)
    if [[ -z "$CONTENT_RAW" || "$CONTENT_RAW" == "null" || "$CONTENT_RAW" == "empty" ]]; then
        ERROR_MESSAGE=$(echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq -r '.error.message // empty' 2>/dev/null)
        if [[ -n "$ERROR_MESSAGE" ]]; then
            log_error "API Error: $ERROR_MESSAGE"
            return 1
        fi
    fi

    local content_json
    if echo "$CONTENT_RAW" | jq -e . >/dev/null 2>&1; then
        # AI already returned valid JSON (expected for json_schema); normalize to compact form
        content_json=$(printf '%s' "$CONTENT_RAW" | jq -c .)
    else
        # Fall back to JSON-string encoding for plain text responses
        if ! content_json=$(printf '%s' "$CONTENT_RAW" | jq -Rs '.'); then
            content_json="$CONTENT_RAW"
        fi
    fi

    if [[ -z "$content_json" || "$content_json" == "null" || "$content_json" == "empty" ]]; then
        log_error "No content found in API response after all attempts"
        log_debug "Response structure: $(echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq 'keys' 2>/dev/null || echo "Could not analyze")"
        log_error "Raw response: ${CLEANED_RESPONSE:-$RESPONSE}"
        return 1
    fi

    echo "$content_json"
}

# Query the Copilot headless CLI as an alternative provider. Accepts the same
# OpenAI chat/completions-style payload as get-openai-response (a messages array
# plus an optional response_format.json_schema) and returns the model's content
# as a compact JSON string, matching get-openai-response's output contract.
#
# Copilot's headless mode has no structured-output parameter, so the JSON schema
# (when present) is injected into the prompt text. All MCP servers and built-in
# tools are disabled for speed and determinism. gpt-5.x models bill zero premium
# requests here.
get-copilot-response() {
    log_debug "Preparing request for Copilot headless CLI"

    if ! command -v copilot >/dev/null 2>&1; then
        log_error "copilot CLI not found on PATH"
        return 1
    fi

    local payload="$1"

    local system_msg user_msg schema
    system_msg=$(printf '%s' "$payload" | jq -r '[.messages[] | select(.role=="system") | .content] | join("\n\n")' 2>/dev/null)
    user_msg=$(printf '%s' "$payload" | jq -r '[.messages[] | select(.role=="user") | .content] | join("\n\n")' 2>/dev/null)
    schema=$(printf '%s' "$payload" | jq -c '.response_format.json_schema.schema // empty' 2>/dev/null)

    local prompt="$system_msg"$'\n\n'"$user_msg"
    if [[ -n "$schema" && "$schema" != "null" ]]; then
        prompt+=$'\n\n'"Return ONLY a single minified JSON object that validates against the JSON Schema below. Emit no prose, no explanation, and no code fences."$'\n'"JSON Schema:"$'\n'"$schema"
    fi

    # Lean invocation: disable the built-in and every configured MCP server, and
    # expose no tools, so no servers connect. Keeps latency low (~4s) and output
    # deterministic.
    local -a cop_flags
    cop_flags=(
        -p "$prompt"
        --model "${COPILOT_MODEL:-gpt-5.4}"
        --output-format json
        --no-color
        --disable-builtin-mcps
        --available-tools ""
    )
    local mcp_config="${COPILOT_CONFIG_HOME:-$HOME/.copilot}/mcp-config.json"
    if [[ -f "$mcp_config" ]]; then
        local server
        for server in $(jq -r '.mcpServers // {} | keys[]' "$mcp_config" 2>/dev/null); do
            cop_flags+=(--disable-mcp-server "$server")
        done
    fi

    local out_file
    out_file=$(mktemp)

    local attempt=0 max_attempts=3 sleep_base=2 cop_status=0
    while ((attempt < max_attempts)); do
        attempt=$((attempt + 1))
        copilot "${cop_flags[@]}" >"$out_file" 2>/dev/null
        cop_status=$?
        [[ $cop_status -eq 0 ]] && break
        log_warn "Copilot request failed (attempt $attempt/$max_attempts); retrying after backoff"
        command sleep $((sleep_base ** attempt))
    done

    if [[ $cop_status -ne 0 ]]; then
        command rm -f "$out_file"
        log_error "Copilot CLI failed after $max_attempts attempts"
        return 1
    fi

    local premium
    premium=$(jq -r 'select(.type=="result") | .usage.premiumRequests // empty' "$out_file" 2>/dev/null | tail -1) || premium=""
    [[ -n "$premium" ]] && log_debug "Copilot premiumRequests=$premium"

    local content_raw
    content_raw=$(jq -r 'select(.type=="assistant.message") | .data.content' "$out_file" 2>/dev/null | tail -1) || content_raw=""
    command rm -f "$out_file"

    if [[ -z "$content_raw" || "$content_raw" == "null" ]]; then
        log_error "No assistant content found in Copilot response"
        return 1
    fi

    # Defensive: strip code fences the model may have added despite instructions.
    content_raw=${content_raw//'```json'/}
    content_raw=${content_raw//'```'/}

    local content_json
    if print -r -- "$content_raw" | jq -e . >/dev/null 2>&1; then
        content_json=$(print -r -- "$content_raw" | jq -c .)
    else
        # Fallback: reduce to the outermost { ... } span, then re-parse.
        local body="${content_raw#*\{}"
        body="{${body}"
        body="${body%\}*}}"
        if print -r -- "$body" | jq -e . >/dev/null 2>&1; then
            content_json=$(print -r -- "$body" | jq -c .)
        else
            content_json=$(print -r -- "$content_raw" | jq -Rs '.')
        fi
    fi

    if [[ -z "$content_json" || "$content_json" == "null" ]]; then
        log_error "No usable content parsed from Copilot response"
        return 1
    fi

    echo "$content_json"
}

# Provider dispatcher. Routes to the Copilot headless CLI when AI_PROVIDER is
# "copilot"; otherwise uses the OpenAI HTTP provider. Callers that want provider
# selection should invoke this instead of get-openai-response directly.
get-ai-response() {
    if [[ "${AI_PROVIDER:-openai}" == "copilot" ]]; then
        get-copilot-response "$1"
    else
        get-openai-response "$1"
    fi
}

test-openai-connectivity() {
    local model="${1:-$OPENAI_MODEL}"
    local endpoint="${OPENAI_API_BASE_URL%/}/models/${model}"

    log_info "Testing OpenAI API connectivity for model '$model'"

    local tmp_response
    tmp_response=$(mktemp)

    local http_status
    if ! http_status=$(curl -sS -o "$tmp_response" -w "%{http_code}" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
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
