#!/usr/bin/env zsh
set -e
# set -x

# Set variables used in the script
##################################################
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
PDF_FILE="$1"
PAPERWORK_DIR="$HOME/Documents/Paperwork"

# Get tokens and keys from 1Password
export ***REMOVED***
AZURE_OPENAI_ENDPOINT=$(op read -n "op://cli/aoi-martinez/url")
AZURE_OPENAI_TOKEN=$(op read -n "op://cli/aoi-martinez/token")
API_KEY=$(op read -n "op://cli/aoi-martinez/api-key")

# Helper functions
##################################################
echo-json() {
    echo $1 | jq . | bat --language=json --paging=never --style=numbers
}

strip-file-tags() {
    if xattr -p "com.apple.metadata:_kMDItemUserTags" "$1" >/dev/null 2>&1; then
        xattr -d "com.apple.metadata:_kMDItemUserTags" "$1"
    fi
}

set-finder-comments() {
    osascript -e 'on run {f, c}' -e 'tell app "Finder" to set comment of (POSIX file f as alias) to c' -e end "file://$1" "$2"
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

get-scanned-at() {
    echo "$1" |
        grep -oE '([0-9]{4})-([0-9]{2})-([0-9]{2})[-T]([0-9]{2})-([0-9]{2})-([0-9]{2})' |
        sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)[-T]\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1-\2-\3T\4-\5-\6/'
}

get-folder-list() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | tr '\n' ',' | sed 's/,$//'
}

get-pdf-text() {
    RAW_TEXT=$(pdftotext -nopgbrk -raw "$1" -)
    escape-text "$RAW_TEXT"
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

    # Parse the response to get the categorization and date
    echo "$RESPONSE" | jq -r '.choices[0].message.content'
}

# Process Functions
##################################################

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

# Prepare - Start with things we can determine from the file itself
##################################################

# Extract the date from the filename (should be in this format 2023-12-06T10-40-27)
SCANNED_AT=$(get-scanned-at "$PDF_FILE")
if [ -z "$SCANNED_AT" ]; then
    echo "Error: Scanned DateTime not found in the filename $PDF_FILE."
    exit -1
fi

PDF_TEXT=$(get-pdf-text "$PDF_FILE")
if [ -z "$PDF_TEXT" ]; then
    echo "Failed to extract and/or sanitize text from the PDF."
    exit -1
fi

# Get a list of all top-level folders under $PAPERWORK_DIR
TOP_LEVEL_FOLDERS=$(get-folder-list "$PAPERWORK_DIR")
if [ -z "$TOP_LEVEL_FOLDERS" ]; then
    echo "No folders found in $PAPERWORK_DIR."
    exit -1
fi

# clear the attributes on the file to avoid double processing
strip-file-tags "$PDF_FILE"

# Execute - use AI to process file
##################################################
AI_RESPONSE=$(initial-ai-processing "$PDF_TEXT" "$TOP_LEVEL_FOLDERS")
echo-json "$AI_RESPONSE"

# Save the parsed values to environment variables
SENDER=$(echo "$AI_RESPONSE" | jq -r '.sender')

DEPARTMENT=$(echo "$AI_RESPONSE" | jq -r '.department')
if [ "$DEPARTMENT" = "null" ]; then
    DEPARTMENT=""
fi

SENT_ON=$(echo "$AI_RESPONSE" | jq -r '.sentOn' | tr '/: ' '-')

CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.category')

SHORT_SUMMARY=$(echo "$AI_RESPONSE" | jq -r '.shortSummary' | tr '"' "'")

if [ -z "$SENDER" ] || [ "$SENDER" = "null" ] ||
    [ -z "$SCANNED_AT" ] || [ "$SCANNED_AT" = "null" ] ||
    [ -z "$CATEGORY" ] || [ "$CATEGORY" = "null" ] ||
    [ -z "$SHORT_SUMMARY" ] || [ "$SHORT_SUMMARY" = "null" ]; then
    echo "Error: One or more required fields are empty or null."
    exit -1
fi

CATEGORY_DIR="$PAPERWORK_DIR/$CATEGORY"
SENDER_DIR="$CATEGORY_DIR/$SENDER"

# Check if there is already a category folder; if not, we can reduce processing since
# everything will be new
if [ ! -d "$CATEGORY_DIR" ]; then
    echo "Creating new category folder: $CATEGORY_DIR"
    mkdir -p "$CATEGORY_DIR"
else
    # if there is already a sender directory, we can reduce processing as well and
    # assume that it's valid; if not, we'll check the subfolders
    echo "Category folder aleady exists: $CATEGORY_DIR"
    if [ ! -d "$SENDER_DIR" ]; then
        echo "Sender folder doesn't exist; checking for best match: $SENDER_DIR"

        SENDER_SUBFOLDERS=$(get-folder-list "$CATEGORY_DIR")
        SENDER_AI_RESPONSE=$(check-subfolders-with-ai "$SENDER_SUBFOLDERS" "$SENDER" "$SHORT_SUMMARY")
        echo-json "$SENDER_AI_RESPONSE"

        SUGGESTED_FOLDER=$(echo "$SENDER_AI_RESPONSE" | jq -r '.suggestion')
        if [ -z "$SUGGESTED_FOLDER" ] || [ "$SUGGESTED_FOLDER" = "null" ]; then
            echo "No suggestion provided; creating new sender folder: $SENDER_DIR"
            mkdir -p "$SENDER_DIR"
        else
            SENDER="$SUGGESTED_FOLDER"
            SENDER_DIR="$CATEGORY_DIR/$SENDER"
            echo "Suggestion found, using existing folder: $SENDER_DIR"
        fi
    fi

    # only check department if one was specified
    if [ -n "$DEPARTMENT" ]; then
        DEPARTMENT_DIR="$SENDER_DIR/$DEPARTMENT"
        echo "Department provided, checking if folder exists: $DEPARTMENT_DIR"

        # if the department dir doesn't already exist, check to see if there's a close match
        if [ ! -d "$DEPARTMENT_DIR" ]; then
            echo "Department folder doesn't exist; checking for best match: $DEPARTMENT_DIR"
            DEPARTMENT_SUBFOLDERS=$(get-folder-list "$SENDER_DIR")
            DEPARTMENT_AI_RESPONSE=$(check-subfolders-with-ai "$DEPARTMENT_SUBFOLDERS" "$DEPARTMENT" "$SHORT_SUMMARY")
            echo-json "$DEPARTMENT_AI_RESPONSE"

            SUGGESTED_FOLDER=$(echo "$DEPARTMENT_AI_RESPONSE" | jq -r '.suggestion')
            if [ -z "$SUGGESTED_FOLDER" ] || [ "$SUGGESTED_FOLDER" = "null" ]; then
                echo "No suggestion provided; creating new department folder: $DEPARTMENT_DIR"
                mkdir -p "$DEPARTMENT_DIR"
            else
                DEPARTMENT="$SUGGESTED_FOLDER"
                DEPARTMENT_DIR="$SENDER_DIR/$DEPARTMENT"
                echo "Suggestion found, using existing folder: $DEPARTMENT_DIR"
            fi
        fi

        # update sender dir to include department
        SENDER_DIR="$DEPARTMENT_DIR"
    fi
fi

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

echo "Proposed file name: $NEW_FILE"

cp "$PDF_FILE" "$NEW_FILE"
set-finder-comments "$NEW_FILE" "$SHORT_SUMMARY"

open "$SENDER_DIR"

exit 0
