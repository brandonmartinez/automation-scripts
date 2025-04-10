#!/usr/bin/env zsh

# Set Shell Options
shopt -s extglob

set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# Set variables used in the script
##################################################
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
INPUT_PATH="$1"
BASE_PATH="$HOME/Documents/3D Prints"
NAME="$(basename "$INPUT_PATH")"

exec >$BASE_PATH/logfile.txt 2>&1

# Source Open AI Helpers
##################################################
SCRIPT_DIR="$(cd "$(dirname "${(%):-%N}")" &>/dev/null && pwd)"
echo "Sourcing Open AI Helpers from $SCRIPT_DIR"
source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

# Process Functions
##################################################
OPENAI_SYSTEM_MESSAGE="You're an assistant that helps organize 3D print files, specifically categorizing their folder structures as well as generating or renaming to help organize the files in an easy to navigate way."

generate-name() {
    OPENAI_USER_MESSAGE="Please generate a name for the folder based on the following given name: $1. The name should be title cased, but keep acronyms captialized as appropriate (e.g., when describing printer filament PETG PLA etc). If the name contains any sort of popular media, brand names, or such, but the brand name first and separate from the rest of the name with a hyphen. For example, if the original name is 'R2D2 Star Wars' it should be named 'Star Wars - R2D2'. Remove any redundant information like '3D files' or 'Model Files' or 'Files'. However, if it's describing the type of product it is, that's ok to keep (e.g., Kit Card, Template, etc). Finally, choose a parent folder that this new name aligns to from this list: $2. If there is not a good match, provide a name that could be used for this and future file categorization."

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
                    "originalName": {
                        "type": "string"
                    },
                    "proposedName": {
                        "type": "string"
                    },
                    "proposedFolder": {
                        "type": "string"
                    }
                },
                "required": [
                    "originalName",
                    "proposedName",
                    "proposedFolder"
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

suggest-subfolder() {
    OPENAI_USER_MESSAGE="Out of the following list of subfolders, which one would be the best fit for the file $1? $3. These subfolders have be provided under the current parent category folder $2, please take that into account when choosing. If the subfolder list is N/A or empty, or if there isn't a good match, please suggest a new subfolder name. These could be sub-categories, groupings or brands (e.g., Apple, Raspberry Pi, Star Wars, etc), or some other secondary level of organization. Please keep it generic enough to allow for other files to be categorized in the future."

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
                    "subfolderName": {
                        "type": "string"
                    }
                },
                "required": [
                    "subfolderName"
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

rename-source-file() {
    OPENAI_USER_MESSAGE="Please rename the file $1 to something more appropriate for the its new folder structure. The file is currently categorized under a path of $2/$3/$4. Prefix the new name with '$4', separated with a hyphen and spaces, and provide a name that describes what the specific part is. Please include the file extension in the proposed name, but do not duplicate the extension within the name (i.e., it should only end with one extension). Keep the names short, as it will need to exist on a file system. Be succinct in the naming, for example if it is 'under_leg.step', it should be renamed '$4 - Under Leg.step'. If you are unsure of a good name, just return the original name. For additional context, here are the other sibling files in the same folder (if any): $5; keep in mind that the others will be renamed as well and aim for consistency. Also, if there's a singular .3mf file, that is probably the main profile and should just be named '$4'; if there's more than one, use the same base name but add a descriptor based on whatever context is in the original file name separated with a hyphen."
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
                    "originalName": {
                        "type": "string"
                    },
                    "proposedName": {
                        "type": "string"
                    }
                },
                "required": [
                    "originalName",
                    "proposedName"
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

# Start Processing
##################################################

TOP_LEVEL_FOLDERS=$(get-folder-list "$BASE_PATH")
if [ -z "$TOP_LEVEL_FOLDERS" ]; then
    echo "No folders found in $BASE_PATH."
    exit -1
fi

echo "**************************************************\n"
echo "Generating a new name for the folder $NAME and selecting a new location"
AI_RESPONSE=$(generate-name "$NAME" "$TOP_LEVEL_FOLDERS")
echo-json "$AI_RESPONSE"
PROPOSED_NAME=$(echo "$AI_RESPONSE" | jq -r '.proposedName')
CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.proposedFolder')
CATEGORY_DIR="$BASE_PATH/$CATEGORY"

if [[ -z "$PROPOSED_NAME" || "$PROPOSED_NAME" == "null" || -z "$CATEGORY" || "$CATEGORY" == "null" ]]; then
    echo "Error: Proposed name or category is null or empty. Exiting."
    exit 1
fi

echo "**************************************************\n"
echo "Organizing into $CATEGORY and selecting an appropriate sub-folder."

if [ ! -d "$CATEGORY_DIR" ]; then
    echo "Category folder '$CATEGORY' does not exist; creating a new folder."
    mkdir -p "$CATEGORY_DIR"
else
    echo "Category folder '$CATEGORY' aleady exists."
fi

SUBFOLDER_LIST=$(get-folder-list "$CATEGORY_DIR")

if [ -z "$SUBFOLDER_LIST" ]; then
    SUBFOLDER_LIST="N/A"
fi

AI_RESPONSE=$(suggest-subfolder "$NAME" "$CATEGORY" "$SUBFOLDER_LIST")
echo-json "$AI_RESPONSE"
SUBCATEGORY=$(echo "$AI_RESPONSE" | jq -r '.subfolderName')
SUBCATEGORY_DIR="$CATEGORY_DIR/$SUBCATEGORY"

if [[ -z "$SUBCATEGORY" || "$SUBCATEGORY" == "null" ]]; then
    echo "Error: Subcategory is null or empty. Exiting."
    exit 1
fi

if [ ! -d "$SUBCATEGORY_DIR" ]; then
    echo "Sub-category folder '$SUBCATEGORY' does not exist; creating a new folder."
    mkdir -p "$SUBCATEGORY_DIR"
else
    echo "Sub-category folder '$SUBCATEGORY' aleady exists."
fi

# TODO: check if there's already a folder called this, if so ask for another name until it doesn't exist

NEW_FILEPATH="$SUBCATEGORY_DIR/$PROPOSED_NAME"
RENAME_FILE="$NEW_FILEPATH/RENAMES.txt"

echo "**************************************************\n"
echo "Moving $INPUT_PATH to $NEW_FILEPATH"

mv "$INPUT_PATH" "$NEW_FILEPATH"
echo "$INPUT_PATH => $NEW_FILEPATH" >> "$RENAME_FILE"

echo "**************************************************\n"
echo "Opening $NEW_FILEPATH in Finder"
open "$NEW_FILEPATH"
touch "$RENAME_FILE"

echo "**************************************************\n"
echo "Flattening the original folder structure of $INPUT_PATH"

export NEW_FILEPATH
export RENAME_FILE
find "$NEW_FILEPATH" -mindepth 2 -type f -exec sh -c '
    for file; do
        base_file_name="$(basename "$file")"
        relative_path="${file#$NEW_FILEPATH/}"
        new_path="$NEW_FILEPATH/$(basename "$NEW_FILEPATH")_$base_file_name"
        echo "$relative_path => $(basename "$file")" >> "$RENAME_FILE"
        echo "Moving $file to $new_path"
        mv "$file" "$new_path"
    done
' sh {} +
find "$NEW_FILEPATH" -mindepth 1 -type d -empty -delete

echo "**************************************************\n"
echo "Creating new folder structure for files under $NEW_FILEPATH."

FILES_FOLDER="$NEW_FILEPATH/files"
IMAGES_FOLDER="$NEW_FILEPATH/images"
EXPORTS_FOLDER="$NEW_FILEPATH/exports"
MISC_FOLDER="$NEW_FILEPATH/misc"

echo "Adding Subfolders"
mkdir -p "$FILES_FOLDER"
mkdir -p "$IMAGES_FOLDER"
mkdir -p "$EXPORTS_FOLDER"
mkdir -p "$MISC_FOLDER"

echo "Converting file extensions to lowercase in $FILES_FOLDER"
for file in "$NEW_FILEPATH"/*; do
    BASENAME=$(basename "$file")
    EXTENSION="${BASENAME##*.}"
    FILENAME="${BASENAME%.*}"
    LOWERCASE_EXTENSION=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')
    if [[ "$EXTENSION" != "$LOWERCASE_EXTENSION" ]]; then
        NEW_FILENAME="$FILENAME.$LOWERCASE_EXTENSION"
        if [[ ! -e "$FILES_FOLDER/$NEW_FILENAME" ]]; then
            echo "Renaming $file to $NEW_FILENAME"
            mv "$file" "$FILES_FOLDER/$NEW_FILENAME"
        else
            echo "File $NEW_FILENAME already exists, skipping rename for $file"
        fi
    fi
done

echo "Moving 3D Files into $FILES_FOLDER"
mv "$NEW_FILEPATH/"*.(stl|f3d|3mf|step|stp|scad|blend|shapr) "$FILES_FOLDER/" 2>/dev/null || true

echo "Moving Images into $IMAGES_FOLDER"
mv "$NEW_FILEPATH/"*.(jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff) "$IMAGES_FOLDER/" 2>/dev/null || true

echo "Moving GCODE into $EXPORTS_FOLDER"
mv "$NEW_FILEPATH/"*.gcode "$EXPORTS_FOLDER/" 2>/dev/null || true

echo "Moving All Other Non-Doc Files into $MISC_FOLDER"
mv "$NEW_FILEPATH/"*.!(txt|pdf|html|htm|md|rtf|doc) "$MISC_FOLDER/" 2>/dev/null || true

echo "**************************************************\n"
echo "Renaming files in $FILES_FOLDER"
ALL_SIBLING_FILES=$(ls "$FILES_FOLDER" | tr '\n' ',' | sed 's/,$//')
for file in "$FILES_FOLDER"/*; do
    BASENAME=$(basename "$file")

    echo "Renaming $file"

    AI_RESPONSE=$(rename-source-file "$BASENAME" "$CATEGORY" "$SUBCATEGORY" "$PROPOSED_NAME" "$ALL_SIBLING_FILES")
    echo-json "$AI_RESPONSE"
    PROPOSED_FILENAME=$(echo "$AI_RESPONSE" | jq -r '.proposedName')

    if [[ "$PROPOSED_FILENAME" != "null" && ! -e "$FILES_FOLDER/$PROPOSED_FILENAME" ]]; then
        echo "$file => $PROPOSED_FILENAME" >> "$RENAME_FILE"
        mv "$file" "$FILES_FOLDER/$PROPOSED_FILENAME"
    else
        echo "Skipping rename for $file as the proposed filename is either 'null' or already exists."
    fi
done


echo "**************************************************\n"
echo "Renaming top-level README documents in $NEW_FILEPATH"

for file in "$NEW_FILEPATH"/*.(txt|pdf|html|htm|md|rtf|doc); do
    BASENAME=$(basename "$file")

    LOWERCASE_BASENAME=$(echo "${BASENAME%.*}" | tr '[:upper:]' '[:lower:]')
    if [[ "$LOWERCASE_BASENAME" != "license" && "$LOWERCASE_BASENAME" != "renames" ]]; then
        EXTENSION="${BASENAME##*.}"
        NEW_FILENAME="$PROPOSED_NAME.$EXTENSION"
        if [[ ! -e "$NEW_FILEPATH/$NEW_FILENAME" ]]; then
            echo "Renaming $file to $NEW_FILENAME"
            echo "$file => $NEW_FILENAME" >> "$RENAME_FILE"
            mv "$file" "$NEW_FILEPATH/$NEW_FILENAME"
        else
            echo "File $NEW_FILENAME already exists, skipping rename for $file"
        fi
    fi
done

echo "**************************************************\n"
echo "Done."

exit 0
