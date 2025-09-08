#!/usr/bin/env zsh

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "Video Stabilization in Folder"

####################################################################################
# This script searches the passed in directory for video files (*.mp4, *.mov, *.m4v)
# and stabilizes them using ffmpeg and libvidstab (required before running). It will
# create a transform file (*.trf), then use the information to create a new video
# with a `-stabilized` suffix.
#
# Based on https://www.paulirish.com/2021/video-stabilization-with-ffmpeg-and-vidstab/
####################################################################################

# Required! Install the following first:
# brew install ffmpeg
# rew install libvidstab

DIRECTORY=$1

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <directory>"
    log_error "Please provide a directory containing video files to stabilize"
    exit 1
fi

# Check if input directory exists
if [[ ! -d "$DIRECTORY" ]]; then
    log_error "Directory not found: $DIRECTORY"
    exit 1
fi

# Check if required tools are available
if ! command -v ffmpeg >/dev/null 2>&1; then
    log_error "ffmpeg command not found. Please install it first:"
    log_error "  brew install ffmpeg"
    exit 1
fi

log_info "Starting video stabilization for directory: $DIRECTORY"

FILE_PATH_FILTER="$1/*.@(mp4|mov|m4v)"

# Enable extended patterns and ignore casing
shopt -s extglob
shopt -s nocaseglob

# Count files first
file_count=0
for file in $FILE_PATH_FILTER; do
    [ -f "$file" ] && ((file_count++))
done

if [[ $file_count -eq 0 ]]; then
    log_warn "No video files found in $DIRECTORY"
    exit 0
fi

log_info "Found $file_count video file(s) to process"

# Loop through files
current_file=0
for file in $FILE_PATH_FILTER
do
    # If there are no files, break
    [ -f "$file" ] || break

    ((current_file++))
    log_info "Processing file $current_file of $file_count: $(basename "$file")"

    # Get path and filename components
    DIRNAME=$(dirname "$file")
    FILENAME=$(basename -- "$file")
    EXTENSION="${FILENAME##*.}"
    FILENAME="${FILENAME%.*}"

    # Build new filenames
    TRANSFORM_FILE="$DIRNAME/$FILENAME.trf"
    STABILIZED_FILE="$DIRNAME/$FILENAME-stabilized.$EXTENSION"

    # Check if stabilized file already exists
    if [[ -f "$STABILIZED_FILE" ]]; then
        log_warn "Stabilized file already exists, skipping: $(basename "$STABILIZED_FILE")"
        continue
    fi

    # Get stabilization data
    log_info "Creating stabilization data from $(basename "$file")"
    log_debug "Transform file: $TRANSFORM_FILE"
    if ffmpeg -i "$file" -vf vidstabdetect=result="$TRANSFORM_FILE" -f null - 2>/dev/null; then
        log_info "Stabilization data created successfully"
    else
        log_error "Failed to create stabilization data for $(basename "$file")"
        continue
    fi

    # Transform the video and output to new file
    log_info "Transforming $(basename "$file") with stabilization data"
    log_debug "Output file: $STABILIZED_FILE"
    if ffmpeg -i "$file" -vf vidstabtransform=input="$TRANSFORM_FILE" "$STABILIZED_FILE" 2>/dev/null; then
        log_info "Successfully created stabilized video: $(basename "$STABILIZED_FILE")"

        # Clean up transform file
        if [[ -f "$TRANSFORM_FILE" ]]; then
            rm "$TRANSFORM_FILE"
            log_debug "Cleaned up transform file: $(basename "$TRANSFORM_FILE")"
        fi
    else
        log_error "Failed to create stabilized video for $(basename "$file")"
    fi
done

log_info "Video stabilization completed for directory: $DIRECTORY"
log_info "Processed $current_file of $file_count video files"
