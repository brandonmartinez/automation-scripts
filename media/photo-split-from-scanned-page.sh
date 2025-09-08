#!/usr/bin/env zsh

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "Photo Split from Scanned Page"

SCANNED_PAGE_PATH="$1"

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <scanned_page_image>"
    log_error "Please provide a scanned page image file to split"
    exit 1
fi

# Check if input file exists
if [[ ! -f "$SCANNED_PAGE_PATH" ]]; then
    log_error "Input file not found: $SCANNED_PAGE_PATH"
    exit 1
fi

log_info "Processing scanned page: $(basename "$SCANNED_PAGE_PATH")"

ORIGINAL_FOLDER=$(dirname "$SCANNED_PAGE_PATH")
BASENAME=$(basename "$SCANNED_PAGE_PATH" .jpg)

cd "$ORIGINAL_FOLDER"

log_info "Extracting photos from $(basename "$SCANNED_PAGE_PATH")"
log_debug "Using multicrop2 script with SouthEast corner detection"

if "$SCRIPT_DIR/photo-multicrop2.sh" -c SouthEast -f 10 -d 10000 "$SCANNED_PAGE_PATH" "$BASENAME.jpg"; then
    log_info "Successfully extracted individual photos"
else
    log_error "Failed to extract photos from scanned page"
    exit 1
fi

# Create directories for processing
mkdir -p "$ORIGINAL_FOLDER/split"
mkdir -p "$ORIGINAL_FOLDER/processed"

log_info "Processing extracted photos with Topaz Photo AI"

file_count=0
for file in "${BASENAME}"*; do
    [[ -f "$file" ]] && ((file_count++))
done

if [[ $file_count -eq 0 ]]; then
    log_warn "No extracted photos found to process"
    exit 0
fi

log_info "Found $file_count extracted photo(s) to process"

current_file=0
for file in "${BASENAME}"*; do
    if [[ -f "$file" ]]; then
        ((current_file++))
        log_info "Processing photo $current_file of $file_count: $(basename "$file")"

        # Move to split directory
        mv "$file" "$ORIGINAL_FOLDER/split/"
        file="$ORIGINAL_FOLDER/split/$(basename "$file")"

        # Process with Topaz Photo AI
        log_debug "Running Topaz Photo AI on $(basename "$file")"
        if /Applications/Topaz\ Photo\ AI.app/Contents/MacOS/Topaz\ Photo\ AI --cli "$file" --output "$ORIGINAL_FOLDER/processed/" >/dev/null 2>&1; then
            log_info "Successfully processed $(basename "$file") with Topaz Photo AI"
        else
            log_warn "Failed to process $(basename "$file") with Topaz Photo AI"
        fi
    fi
done

log_info "Opening result directories"
open "$ORIGINAL_FOLDER/split"
open "$ORIGINAL_FOLDER/processed"

log_info "Photo splitting and processing completed"
log_info "Processed $current_file of $file_count extracted photos"
