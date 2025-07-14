#!/usr/bin/env zsh

set -a

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
# Get tokens and keys from 1Password
***REMOVED***
AZURE_OPENAI_ENDPOINT=$(op read -n "op://cli/aoi-martinez/url")
AZURE_OPENAI_TOKEN=$(op read -n "op://cli/aoi-martinez/token")
API_KEY=$(op read -n "op://cli/aoi-martinez/api-key")

set +a

echo-json() {
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
    echo $1 | tr -cd 'A-Za-z0-9'
}

get-pdf-text() {
    RAW_TEXT=$(pdftotext -nopgbrk -raw "$1" -)
    escape-text "$RAW_TEXT"
}

get-folder-list() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ',' | sed 's/,$//'
}

get-openai-response() {
    # Send the extracted text to the Azure OpenAI endpoint
    RESPONSE=$(curl -s -X POST "$AZURE_OPENAI_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AZURE_OPENAI_TOKEN" \
        -H "api-key: $API_KEY" \
        -d "$1")

    # Check if the request was successful
    if [ $? -ne 0 ]; then
        echo "Failed to send the text to the Azure OpenAI endpoint."
        exit -1
    fi    # Try to parse the response directly first
    echo "Full API Response:" >&2

    # First, let's check if we can extract content without validating the entire JSON
    CONTENT=$(printf '%s' "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [[ -n "$CONTENT" && "$CONTENT" != "null" && "$CONTENT" != "empty" ]]; then
        echo "Content extracted directly from raw response" >&2
        echo "DEBUG: Direct extraction successful, content length: ${#CONTENT}" >&2
    else
        # If direct extraction failed, try with full JSON validation
        if echo "$RESPONSE" | jq . >&2 2>/dev/null; then
            echo "JSON parsed successfully (raw response)" >&2
            CLEANED_RESPONSE="$RESPONSE"
        else
            echo "Raw response failed JSON parsing, attempting to clean..." >&2
            # Clean the response of control characters before JSON parsing
            CLEANED_RESPONSE=$(printf '%s' "$RESPONSE" | tr -d '\000-\010\013\014\016-\037\177')

            if echo "$CLEANED_RESPONSE" | jq . >&2 2>/dev/null; then
                echo "JSON parsed successfully (after cleaning)" >&2
            else
                echo "Warning: Could not parse response as JSON even after cleaning, showing raw response:" >&2
                echo "$CLEANED_RESPONSE" >&2
            fi
        fi

        # Re-extract content from cleaned response if needed
        if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
            CONTENT=$(echo "$CLEANED_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        fi
    fi
    echo "" >&2    # Check if response contains an error (skip if we already have content)
    if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
        ERROR_MESSAGE=$(echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq -r '.error.message // empty' 2>/dev/null)
        if [[ -n "$ERROR_MESSAGE" ]]; then
            echo "API Error: $ERROR_MESSAGE" >&2
            exit -1
        fi
    fi

    # Final content validation and debugging
    echo "DEBUG: Final content validation..." >&2
    echo "DEBUG: Content length: ${#CONTENT}" >&2
    echo "DEBUG: Content preview: '${CONTENT:0:100}...'" >&2

    if [[ -z "$CONTENT" || "$CONTENT" == "null" || "$CONTENT" == "empty" ]]; then
        echo "Error: No content found in API response after all attempts" >&2
        echo "DEBUG: Response structure analysis:" >&2
        echo "${CLEANED_RESPONSE:-$RESPONSE}" | jq 'keys' >&2 2>/dev/null || echo "Could not analyze response structure" >&2
        exit -1
    fi

    # Parse the response to get the categorization and date
    echo "$CONTENT"
}
