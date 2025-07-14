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

get-file-list() {
    find "$1" -type f -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//'
}

get-folder-structure() {
    local base_path="$1"
    local structure=""

    # Check if base path exists
    if [[ ! -d "$base_path" ]]; then
        echo "Base path does not exist: $base_path"
        return 1
    fi

    # Set nullglob to handle cases where no directories match
    setopt nullglob

    # Get top-level folders and their subfolders
    for category in "$base_path"/*; do
        if [[ -d "$category" ]]; then
            category_name=$(basename "$category")
            structure="$structure$category_name:\n"

            # Get subfolders for this category
            local subfolders=""
            for subfolder in "$category"/*; do
                if [[ -d "$subfolder" ]]; then
                    subfolder_name=$(basename "$subfolder")
                    subfolders="$subfolders  - $subfolder_name\n"
                fi
            done

            if [[ -n "$subfolders" ]]; then
                structure="$structure$subfolders"
            else
                structure="$structure  - (no subfolders)\n"
            fi
            structure="$structure\n"
        fi
    done

    # Unset nullglob to restore default behavior
    unsetopt nullglob

    if [[ -z "$structure" ]]; then
        echo "No directories found in $base_path"
        return 1
    fi

    echo -e "$structure"
}

organize-all-files() {
    FOLDER_NAME="$1"
    FOLDER_STRUCTURE="$2"
    FULL_FILE_LIST="$3"

    OPENAI_USER_MESSAGE="Please analyze and organize the following 3D print folder and its files in a single comprehensive response:

FOLDER TO ORGANIZE: '$FOLDER_NAME'

ALL FILES IN FOLDER: $FULL_FILE_LIST

EXISTING FOLDER STRUCTURE:
$FOLDER_STRUCTURE

Please provide a complete organization plan including:

1. FOLDER NAMING: Generate a proper name for the main folder. The name should be title cased, but keep acronyms capitalized as appropriate (e.g., PETG, PLA, etc). If the name contains popular media or brand names, put the brand name first and separate from the rest with a hyphen. For example, 'R2D2 Star Wars' should be 'Star Wars - R2D2'. Remove redundant information like '3D files' or 'Model Files', but keep product type descriptors (e.g., Kit Card, Template).

2. CATEGORIZATION: Choose the best parent category from the existing folder structure above, or suggest a new category name if none fit well. Consider the hierarchical organization shown.

3. SUBCATEGORIZATION: Suggest an appropriate subfolder name under the chosen category. Look at the existing subfolders in that category to maintain consistency. This could be a sub-category, grouping, brand (e.g., Apple, Raspberry Pi, Star Wars), or other secondary organization level. Try to fit with the existing organizational pattern.

4. FILE RENAMING: For each file in the list, provide a renamed version that follows these rules:
   - Prefix with the proposed folder name, separated by ' - '
   - IMPORTANT: Preserve any model numbers, part numbers, or specific model names from the original filename
   - Include file extension
   - Keep names filesystem-friendly and concise
   - For .3mf files: if there's only one, name it just the folder name; if multiple, add descriptors
   - For other 3D files (.stl, .step, etc): describe the specific part, but include original model numbers/names
   - For documentation files: use the folder name as base but preserve any version numbers or specific identifiers
   - Examples: 'iPhone_15_case.stl' should become 'Phone Case - iPhone 15.stl', 'bearing_608zz.stl' should become 'Bearing - 608ZZ.stl'
   - Maintain consistency across related files
   - Extract and preserve meaningful identifiers like part numbers, model designations, sizes, or versions

5. FILE CATEGORIZATION: Categorize each file into one of these subfolders:
   - files/ (for 3D model files: .stl, .f3d, .3mf, .step, .stp, .scad, .blend, .shapr)
   - images/ (for images: .jpg, .jpeg, .png, .heic, .heif, .bmp, .gif, .webp, .tif, .tiff)
   - exports/ (for .gcode files)
   - misc/ (for other non-documentation files)
   - root/ (for documentation: .txt, .pdf, .html, .htm, .md, .rtf, .doc)

Please be thorough and consistent in your recommendations."

    # Escape the message content for JSON
    ESCAPED_SYSTEM_MESSAGE=$(echo "$OPENAI_SYSTEM_MESSAGE" | jq -R -s .)
    ESCAPED_USER_MESSAGE=$(echo "$OPENAI_USER_MESSAGE" | jq -R -s .)

    # Create the JSON payload using jq to ensure proper escaping
    JSON_PAYLOAD=$(jq -n \
        --argjson system_msg "$ESCAPED_SYSTEM_MESSAGE" \
        --argjson user_msg "$ESCAPED_USER_MESSAGE" \
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
                    "name": "ComprehensiveFileOrganization",
                    "strict": true,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "originalFolderName": {
                                "type": "string"
                            },
                            "proposedFolderName": {
                                "type": "string"
                            },
                            "parentCategory": {
                                "type": "string"
                            },
                            "subCategory": {
                                "type": "string"
                            },
                            "fileOrganization": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "originalFileName": {
                                            "type": "string"
                                        },
                                        "proposedFileName": {
                                            "type": "string"
                                        },
                                        "targetSubfolder": {
                                            "type": "string",
                                            "enum": ["files", "images", "exports", "misc", "root"]
                                        }
                                    },
                                    "required": [
                                        "originalFileName",
                                        "proposedFileName",
                                        "targetSubfolder"
                                    ],
                                    "additionalProperties": false
                                }
                            }
                        },
                        "required": [
                            "originalFolderName",
                            "proposedFolderName",
                            "parentCategory",
                            "subCategory",
                            "fileOrganization"
                        ],
                        "additionalProperties": false
                    }
                }
            }
        }')

    get-openai-response "$JSON_PAYLOAD"
}

# Start Processing
##################################################

# Get hierarchical folder structure instead of just top-level folders
FOLDER_STRUCTURE=$(get-folder-structure "$BASE_PATH")
if [[ $? -ne 0 || -z "$FOLDER_STRUCTURE" ]]; then
    echo "Warning: Could not get folder structure from $BASE_PATH."
    echo "This might be the first time organizing, or the path might not exist."
    FOLDER_STRUCTURE="No existing categories found. Please suggest appropriate categories for 3D print organization."
fi

echo "Current folder structure:"
echo -e "$FOLDER_STRUCTURE"

# Create backup of original folder structure
echo "**************************************************\n"
echo "Creating backup of original folder structure"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="${NAME}_backup_${TIMESTAMP}.zip"
BACKUP_PATH="$BASE_PATH/$BACKUP_NAME"

# Create zip backup of the original folder
cd "$(dirname "$INPUT_PATH")"
zip -r "$BACKUP_PATH" "$(basename "$INPUT_PATH")" >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "Backup created successfully: $BACKUP_PATH"
else
    echo "Warning: Failed to create backup. Continuing with organization..."
fi

echo "**************************************************\n"
echo "Flattening the original folder structure before AI processing"

# Remove OS-generated files that shouldn't be organized
echo "Removing OS-generated files..."
find "$INPUT_PATH" -name ".DS_Store" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "Thumbs.db" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "thumbs.db" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "desktop.ini" -delete 2>/dev/null || true
find "$INPUT_PATH" -name ".localized" -delete 2>/dev/null || true
find "$INPUT_PATH" -name "._*" -delete 2>/dev/null || true

# Flatten any nested folder structure to give AI complete visibility of all files
export INPUT_PATH
find "$INPUT_PATH" -mindepth 2 -type f -exec sh -c '
    for file; do
        base_file_name="$(basename "$file")"
        relative_path="${file#$INPUT_PATH/}"
        new_path="$INPUT_PATH/$(basename "$INPUT_PATH")_$base_file_name"
        echo "Flattening: $relative_path => $(basename "$new_path")"
        mv "$file" "$new_path"
    done
' sh {} +
find "$INPUT_PATH" -mindepth 1 -type d -empty -delete

# Get complete file list from the source folder AFTER flattening
FULL_FILE_LIST=$(get-file-list "$INPUT_PATH")
if [ -z "$FULL_FILE_LIST" ]; then
    echo "No files found in $INPUT_PATH after flattening."
    exit -1
fi

echo "**************************************************\n"
echo "Analyzing folder '$NAME' with files: $FULL_FILE_LIST"
echo "Making comprehensive organization plan with AI..."

# Make single AI call to organize everything
AI_RESPONSE=$(organize-all-files "$NAME" "$FOLDER_STRUCTURE" "$FULL_FILE_LIST")

# Debug: Check if we got a valid response
if [[ -z "$AI_RESPONSE" || "$AI_RESPONSE" == "null" ]]; then
    echo "Error: No response received from OpenAI API. Exiting."
    exit 1
fi

# Debug: Show raw response to help troubleshoot
echo "Raw AI Response:"
echo "$AI_RESPONSE"
echo ""

# Try to parse as JSON and check if it's valid
if ! echo "$AI_RESPONSE" | jq . >/dev/null 2>&1; then
    echo "Error: Invalid JSON response from OpenAI API:"
    echo "$AI_RESPONSE"
    exit 1
fi

echo-json "$AI_RESPONSE"

# Parse the comprehensive response
PROPOSED_NAME=$(echo "$AI_RESPONSE" | jq -r '.proposedFolderName')
CATEGORY=$(echo "$AI_RESPONSE" | jq -r '.parentCategory')
SUBCATEGORY=$(echo "$AI_RESPONSE" | jq -r '.subCategory')

if [[ -z "$PROPOSED_NAME" || "$PROPOSED_NAME" == "null" || -z "$CATEGORY" || "$CATEGORY" == "null" || -z "$SUBCATEGORY" || "$SUBCATEGORY" == "null" ]]; then
    echo "Error: AI response missing required information. Exiting."
    exit 1
fi

CATEGORY_DIR="$BASE_PATH/$CATEGORY"
SUBCATEGORY_DIR="$CATEGORY_DIR/$SUBCATEGORY"
NEW_FILEPATH="$SUBCATEGORY_DIR/$PROPOSED_NAME"
RENAME_FILE="$NEW_FILEPATH/RENAMES.txt"

echo "**************************************************\n"
echo "Creating directory structure:"
echo "Category: $CATEGORY"
echo "Subcategory: $SUBCATEGORY"
echo "Final path: $NEW_FILEPATH"

# Create directory structure
if [ ! -d "$CATEGORY_DIR" ]; then
    echo "Creating category folder: $CATEGORY"
    mkdir -p "$CATEGORY_DIR"
fi

if [ ! -d "$SUBCATEGORY_DIR" ]; then
    echo "Creating subcategory folder: $SUBCATEGORY"
    mkdir -p "$SUBCATEGORY_DIR"
fi

# TODO: check if there's already a folder called this, if so ask for another name until it doesn't exist
if [[ -d "$NEW_FILEPATH" ]]; then
    echo "Warning: Folder '$PROPOSED_NAME' already exists in $SUBCATEGORY_DIR"
    COUNTER=2
    ORIGINAL_PROPOSED_NAME="$PROPOSED_NAME"
    while [[ -d "$SUBCATEGORY_DIR/$PROPOSED_NAME" ]]; do
        PROPOSED_NAME="${ORIGINAL_PROPOSED_NAME} ${COUNTER}"
        NEW_FILEPATH="$SUBCATEGORY_DIR/$PROPOSED_NAME"
        COUNTER=$((COUNTER + 1))
    done
    echo "Using unique name: $PROPOSED_NAME"
    RENAME_FILE="$NEW_FILEPATH/RENAMES.txt"
fi

echo "**************************************************\n"
echo "Moving $INPUT_PATH to $NEW_FILEPATH"

mv "$INPUT_PATH" "$NEW_FILEPATH"
echo "$INPUT_PATH => $NEW_FILEPATH" >> "$RENAME_FILE"

echo "**************************************************\n"
echo "Moving backup file to organized folder"

# Move the backup zip file to the new organized location
if [[ -f "$BACKUP_PATH" ]]; then
    mv "$BACKUP_PATH" "$NEW_FILEPATH/"
    echo "Backup moved to: $NEW_FILEPATH/$(basename "$BACKUP_PATH")"
    echo "Backup: $BACKUP_PATH => $NEW_FILEPATH/$(basename "$BACKUP_PATH")" >> "$RENAME_FILE"
else
    echo "Warning: Backup file not found at $BACKUP_PATH"
fi

echo "**************************************************\n"
echo "Opening $NEW_FILEPATH in Finder"
open "$NEW_FILEPATH"
touch "$RENAME_FILE"

echo "**************************************************\n"
echo "Creating organized folder structure"

FILES_FOLDER="$NEW_FILEPATH/files"
IMAGES_FOLDER="$NEW_FILEPATH/images"
EXPORTS_FOLDER="$NEW_FILEPATH/exports"
MISC_FOLDER="$NEW_FILEPATH/misc"

# Remove any existing conflicting folders first
if [[ -d "$FILES_FOLDER" ]]; then
    echo "Warning: files folder already exists, merging contents..."
fi
if [[ -d "$IMAGES_FOLDER" ]]; then
    echo "Warning: images folder already exists, merging contents..."
fi
if [[ -d "$EXPORTS_FOLDER" ]]; then
    echo "Warning: exports folder already exists, merging contents..."
fi
if [[ -d "$MISC_FOLDER" ]]; then
    echo "Warning: misc folder already exists, merging contents..."
fi

mkdir -p "$FILES_FOLDER"
mkdir -p "$IMAGES_FOLDER"
mkdir -p "$EXPORTS_FOLDER"
mkdir -p "$MISC_FOLDER"

echo "**************************************************\n"
echo "Organizing and renaming files according to AI plan"

# First, handle special files (README, LICENSE) that should stay at root with original names
for file in "$NEW_FILEPATH"/*; do
    if [[ -f "$file" ]]; then
        BASENAME=$(basename "$file")
        LOWERCASE_BASENAME=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')

        # Check if it's a README or LICENSE file (case insensitive)
        if [[ "$LOWERCASE_BASENAME" =~ ^readme(\.|$) || "$LOWERCASE_BASENAME" =~ ^license(\.|$) ]]; then
            echo "Keeping special file at root: $BASENAME"
            echo "Special file preserved: $BASENAME => root/$BASENAME" >> "$RENAME_FILE"
            # File stays where it is, no moving needed
            continue
        fi
    fi
done

# Process each file according to AI recommendations
echo "$AI_RESPONSE" | jq -r '.fileOrganization[] | @base64' | while IFS= read -r file_data; do
    FILE_INFO=$(echo "$file_data" | base64 -d)
    ORIGINAL_NAME=$(echo "$FILE_INFO" | jq -r '.originalFileName')
    PROPOSED_NAME=$(echo "$FILE_INFO" | jq -r '.proposedFileName')
    TARGET_SUBFOLDER=$(echo "$FILE_INFO" | jq -r '.targetSubfolder')

    # Skip README and LICENSE files - they stay at root with original names
    LOWERCASE_ORIGINAL=$(echo "$ORIGINAL_NAME" | tr '[:upper:]' '[:lower:]')
    if [[ "$LOWERCASE_ORIGINAL" =~ ^readme(\.|$) || "$LOWERCASE_ORIGINAL" =~ ^license(\.|$) ]]; then
        continue
    fi

    # Find the actual file (handle case sensitivity and flattened names)
    ACTUAL_FILE=""
    for file in "$NEW_FILEPATH"/*; do
        BASENAME=$(basename "$file")
        if [[ "$BASENAME" == "$ORIGINAL_NAME" || "$BASENAME" == "$(basename "$NEW_FILEPATH")_$ORIGINAL_NAME" ]]; then
            ACTUAL_FILE="$file"
            break
        fi
    done

    if [[ -n "$ACTUAL_FILE" && -f "$ACTUAL_FILE" ]]; then
        # Determine target directory
        case "$TARGET_SUBFOLDER" in
            "files")
                TARGET_DIR="$FILES_FOLDER"
                ;;
            "images")
                TARGET_DIR="$IMAGES_FOLDER"
                ;;
            "exports")
                TARGET_DIR="$EXPORTS_FOLDER"
                ;;
            "misc")
                TARGET_DIR="$MISC_FOLDER"
                ;;
            "root")
                TARGET_DIR="$NEW_FILEPATH"
                ;;
            *)
                TARGET_DIR="$MISC_FOLDER"
                ;;
        esac

        # Convert extension to lowercase
        EXTENSION="${PROPOSED_NAME##*.}"
        FILENAME="${PROPOSED_NAME%.*}"
        LOWERCASE_EXTENSION=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')
        FINAL_NAME="$FILENAME.$LOWERCASE_EXTENSION"

        TARGET_PATH="$TARGET_DIR/$FINAL_NAME"

        # Check if target file already exists
        if [[ ! -e "$TARGET_PATH" ]]; then
            echo "Moving and renaming: $(basename "$ACTUAL_FILE") -> $TARGET_SUBFOLDER/$FINAL_NAME"
            echo "$(basename "$ACTUAL_FILE") => $TARGET_SUBFOLDER/$FINAL_NAME" >> "$RENAME_FILE"
            mv "$ACTUAL_FILE" "$TARGET_PATH"
        else
            echo "Target file $FINAL_NAME already exists in $TARGET_SUBFOLDER"
            # Create a unique name by adding a counter
            COUNTER=2
            ORIGINAL_FINAL_NAME="$FINAL_NAME"
            EXTENSION="${FINAL_NAME##*.}"
            FILENAME="${FINAL_NAME%.*}"
            while [[ -e "$TARGET_DIR/${FILENAME}_${COUNTER}.${EXTENSION}" ]]; do
                COUNTER=$((COUNTER + 1))
            done
            UNIQUE_NAME="${FILENAME}_${COUNTER}.${EXTENSION}"
            echo "Using unique name: $UNIQUE_NAME"
            echo "$(basename "$ACTUAL_FILE") => $TARGET_SUBFOLDER/$UNIQUE_NAME" >> "$RENAME_FILE"
            mv "$ACTUAL_FILE" "$TARGET_DIR/$UNIQUE_NAME"
        fi
    else
        echo "Warning: Could not find file $ORIGINAL_NAME"
    fi
done

echo "**************************************************\n"
echo "Moving any remaining unprocessed files"

# Handle any files that weren't processed by the AI (safety net)
for file in "$NEW_FILEPATH"/*; do
    if [[ -f "$file" ]]; then
        BASENAME=$(basename "$file")
        LOWERCASE_BASENAME=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')

        # Skip README and LICENSE files - they stay at root
        if [[ "$LOWERCASE_BASENAME" =~ ^readme(\.|$) || "$LOWERCASE_BASENAME" =~ ^license(\.|$) ]]; then
            continue
        fi

        EXTENSION="${BASENAME##*.}"
        LOWERCASE_EXT=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')

        case "$LOWERCASE_EXT" in
            stl|f3d|3mf|step|stp|scad|blend|shapr)
                mv "$file" "$FILES_FOLDER/" 2>/dev/null || true
                ;;
            jpg|jpeg|png|heic|heif|bmp|gif|webp|tif|tiff)
                mv "$file" "$IMAGES_FOLDER/" 2>/dev/null || true
                ;;
            gcode)
                mv "$file" "$EXPORTS_FOLDER/" 2>/dev/null || true
                ;;
            txt|pdf|html|htm|md|rtf|doc)
                # Keep documentation files in root
                ;;
            *)
                mv "$file" "$MISC_FOLDER/" 2>/dev/null || true
                ;;
        esac
    fi
done

echo "**************************************************\n"
echo "Done."

exit 0
