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
    fi

    # Debug: Show the full response for troubleshooting
    echo "Full API Response:" >&2
    echo "$RESPONSE" | jq . >&2
    echo "" >&2

    # Check if response contains an error
    ERROR_MESSAGE=$(echo "$RESPONSE" | jq -r '.error.message // empty')
    if [[ -n "$ERROR_MESSAGE" ]]; then
        echo "API Error: $ERROR_MESSAGE" >&2
        exit -1
    fi

    # Check if response has the expected structure
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    if [[ -z "$CONTENT" ]]; then
        echo "Error: No content found in API response" >&2
        echo "Response structure: $(echo "$RESPONSE" | jq 'keys')" >&2
        exit -1
    fi

    # Parse the response to get the categorization and date
    echo "$CONTENT"
}
