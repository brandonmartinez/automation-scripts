#!/usr/bin/env zsh

SCANNED_PAGE_PATH="$1"
ORIGINAL_FOLDER=$(dirname "$SCANNED_PAGE_PATH")
BASENAME=$(basename "$SCANNED_PAGE_PATH" .jpg)

cd "$ORIGINAL_FOLDER"

echo "Extracting photos from $SCANNED_PAGE_PATH"
./$HOME/src/automation-scripts/media/photo-multicrop2.sh -c SouthEast -f 10 -d 10000 "$SCANNED_PAGE_PATH" "$BASENAME.jpg"

for file in "${BASENAME}"*; do
    echo "Processing $file with Topaz Photo AI"
    mkdir -p "$ORIGINAL_FOLDER/split"
    mv "$file" "$ORIGINAL_FOLDER/split/"
    file="$ORIGINAL_FOLDER/split/$(basename "$file")"

    /Applications/Topaz\ Photo\ AI.app/Contents/MacOS/Topaz\ Photo\ AI --cli "$file" --output "$ORIGINAL_FOLDER/processed/"
done

open "$ORIGINAL_FOLDER/split"
open "$ORIGINAL_FOLDER/processed"
