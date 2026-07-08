#!/usr/bin/env zsh

# ============================================================================
# AI PROVIDER ADAPTER / FACADE
# ============================================================================
# Provides a single entry point, get-ai-response, that routes a standard
# OpenAI chat-completions request body (the shape every caller already builds)
# to one of several backends selected by the AI_PROVIDER environment variable:
#
#   AI_PROVIDER=openai   (default)  -> get-openai-response  (direct OpenAI API)
#   AI_PROVIDER=copilot             -> get-copilot-response (GitHub Copilot CLI)
#
# Rationale: the standard, always-on workflow (Hazel go-forward filing) stays on
# the OpenAI API for lowest latency and guaranteed strict json_schema output.
# Large one-off backfill batches can opt into the Copilot CLI backend, which
# bills against included Copilot usage (0 premium requests for gpt-5.4) instead
# of metered OpenAI tokens. The same model (gpt-5.4) is used on both sides so
# results are comparable; only the provider's own system scaffolding differs.
#
# The contract of get-ai-response matches get-openai-response exactly: it takes
# the request body as $1 and echoes the model's message content (compact JSON
# for json_schema requests), returning non-zero on failure.
# ============================================================================

# Ensure the OpenAI backend (and shared helpers/logging) is available.
if ! typeset -f get-openai-response >/dev/null 2>&1; then
    _AI_PROVIDER_DIR="$(cd "$(dirname "${(%):-%N}")" && pwd)"
    source "$_AI_PROVIDER_DIR/open-ai-functions.sh"
fi

# Model used for the Copilot backend. Defaults to the same model as the OpenAI
# backend so behavior is comparable across providers.
COPILOT_MODEL="${COPILOT_MODEL:-${OPENAI_MODEL:-gpt-5.4}}"

# Build the list of flags that disable every configured MCP server, custom
# instructions, auto-update, and coloring so a headless Copilot invocation
# starts as fast as possible (MCP/skills loading otherwise adds ~8-10s/call).
# MCP server names are read dynamically from the active config so this adapts
# to whatever servers the machine has configured.
_copilot_base_flags() {
    local -a flags
    flags=(
        --model "$COPILOT_MODEL"
        --output-format json
        --no-color
        --log-level none
        --no-auto-update
        --no-custom-instructions
        --no-ask-user
        --allow-all-tools
        --disable-builtin-mcps
    )

    local cfg="${COPILOT_HOME:-$HOME/.copilot}/mcp-config.json"
    if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
        local server
        while IFS= read -r server; do
            [[ -n "$server" ]] && flags+=(--disable-mcp-server "$server")
        done < <(jq -r '.mcpServers // {} | keys[]?' "$cfg" 2>/dev/null)
    fi

    print -r -- "${(j: :)flags}"
}

# Extract the assistant's final message content from a Copilot --output-format
# json (JSONL) stream. Copilot emits streaming deltas plus one consolidated
# assistant.message event; we take the last such event's content.
_copilot_extract_content() {
    jq -rc 'select(.type=="assistant.message") | .data.content // empty' 2>/dev/null | tail -n 1
}

# Strip a leading/trailing markdown code fence (```json ... ```) if the model
# wrapped its JSON despite instructions, and trim surrounding whitespace.
_strip_code_fence() {
    printf '%s' "$1" |
        sed -E '1s/^[[:space:]]*```[[:alnum:]]*[[:space:]]*//; $s/[[:space:]]*```[[:space:]]*$//'
}

# ----------------------------------------------------------------------------
# get-copilot-response <openai_request_body_json>
# Routes a standard OpenAI chat-completions request body through the Copilot
# CLI. The system/user messages and the (optional) json_schema are extracted
# from the body and reassembled into a single non-interactive prompt, because
# the Copilot CLI has no response_format parameter. Echoes the compact JSON
# (or text) content on success; returns 1 on failure.
# ----------------------------------------------------------------------------
get-copilot-response() {
    local request_body="$1"

    if ! command -v copilot >/dev/null 2>&1; then
        log_error "Copilot CLI not found on PATH; cannot use AI_PROVIDER=copilot"
        return 1
    fi

    local system_msg user_msg schema
    system_msg=$(printf '%s' "$request_body" | jq -r '[.messages[]? | select(.role=="system") | .content] | join("\n\n") // ""' 2>/dev/null)
    user_msg=$(printf '%s' "$request_body" | jq -r '[.messages[]? | select(.role=="user") | .content] | join("\n\n") // ""' 2>/dev/null)
    schema=$(printf '%s' "$request_body" | jq -c '.response_format.json_schema.schema // empty' 2>/dev/null)

    if [[ -z "$user_msg" && -z "$system_msg" ]]; then
        log_error "Copilot backend: request body had no system or user message"
        return 1
    fi

    # Assemble the prompt. When a json_schema is present, instruct the model to
    # emit a single schema-conformant JSON object and nothing else, since the
    # Copilot CLI cannot enforce structured output the way the OpenAI API does.
    local prompt
    if [[ -n "$schema" ]]; then
        prompt="${system_msg}

You MUST respond with a SINGLE JSON object and NOTHING else. Do not include markdown, do not use code fences, do not add any commentary or explanation before or after the JSON. The object MUST validate against this exact JSON Schema — include every required key, add no extra keys, and respect the described formats:

${schema}

${user_msg}"
    else
        prompt="${system_msg}

${user_msg}"
    fi

    local base_flags
    base_flags=$(_copilot_base_flags)

    # Run the Copilot CLI in a neutral working directory so it never indexes the
    # caller's repository. Retry once on empty/invalid output (covers transient
    # errors and the occasional non-JSON reply).
    local work_dir="${TMPDIR:-/tmp}"
    local attempt=0 max_attempts=2
    local raw content

    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))

        raw=$(copilot -p "$prompt" -C "$work_dir" ${=base_flags} 2>/dev/null)
        content=$(printf '%s\n' "$raw" | _copilot_extract_content)
        content=$(_strip_code_fence "$content")

        if [[ -z "$content" ]]; then
            log_warn "Copilot backend: empty content (attempt $attempt/$max_attempts)"
            continue
        fi

        # For json_schema requests, require valid JSON; normalize to compact.
        if [[ -n "$schema" ]]; then
            local content_json
            if content_json=$(printf '%s' "$content" | jq -ec . 2>/dev/null); then
                print -r -- "$content_json"
                return 0
            fi
            log_warn "Copilot backend: response was not valid JSON (attempt $attempt/$max_attempts)"
            continue
        fi

        # Plain-text request: return content as-is.
        print -r -- "$content"
        return 0
    done

    log_error "Copilot backend: failed to obtain a valid response after $max_attempts attempts"
    return 1
}

# ----------------------------------------------------------------------------
# get-ai-response <openai_request_body_json>
# Provider-dispatching facade. Selects the backend via AI_PROVIDER (default
# openai). Contract matches get-openai-response.
# ----------------------------------------------------------------------------
get-ai-response() {
    local provider="${AI_PROVIDER:-openai}"
    case "$provider" in
        openai)
            get-openai-response "$1"
            ;;
        copilot)
            get-copilot-response "$1"
            ;;
        *)
            log_error "Unknown AI_PROVIDER '$provider' (expected 'openai' or 'copilot')"
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# test-copilot-connectivity
# Lightweight smoke test for the Copilot backend: asks for a tiny JSON object
# and confirms it parses. Mirrors test-openai-connectivity.
# ----------------------------------------------------------------------------
test-copilot-connectivity() {
    log_info "Testing Copilot CLI connectivity for model '$COPILOT_MODEL'"
    local body
    body=$(jq -n '{
        messages: [
            {role:"system", content:"You are a test."},
            {role:"user", content:"Reply with the document category."}
        ],
        response_format: {type:"json_schema", json_schema:{name:"t", strict:true, schema:{
            type:"object", properties:{ok:{type:"boolean"}}, required:["ok"], additionalProperties:false
        }}}
    }')
    local out
    if out=$(AI_PROVIDER=copilot get-copilot-response "$body") && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        log_info "Copilot connectivity check succeeded: $out"
        return 0
    fi
    log_error "Copilot connectivity check failed"
    return 1
}
