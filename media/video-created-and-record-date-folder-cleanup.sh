#!/usr/bin/env zsh

setopt +o nomatch

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "Video Created and Record Date Folder Cleanup"

dir=$1
DEBUG=${DEBUG:-false}

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <directory>"
    log_error "Please provide a directory containing video files to process"
    exit 1
fi

# Check if input directory exists
if [[ ! -d "$dir" ]]; then
    log_error "Directory not found: $dir"
    exit 1
fi

log_info "Processing video files in directory: $dir"

archive_dir="$dir/_archive"
imported_dir="$dir/_imported"

log_info "Creating archive ($archive_dir) and imported ($imported_dir) directories"
mkdir -p "$archive_dir"
mkdir -p "$imported_dir"

# Count files first
file_count=0
for file in "$dir"/*.{mp4,m4v,mpg,mov}; do
    [[ -f "$file" ]] && ((file_count++))
done

if [[ $file_count -eq 0 ]]; then
    log_warn "No video files found in $dir"
    exit 0
fi

log_info "Found $file_count video file(s) to process"

current_file=0
for file in "$dir"/*.{mp4,m4v,mpg,mov}
do
    if [ -f "$file" ]; then
        ((current_file++))
        log_info "Processing file $current_file of $file_count: $(basename "$file")"

        # Call the individual cleanup script
        if "$SCRIPT_DIR/video-created-and-record-date-cleanup.sh" "$file"; then
            log_info "Successfully processed $(basename "$file")"
        else
            log_error "Failed to process $(basename "$file")"
        fi
    fi
done

log_info "Folder cleanup completed for directory: $dir"
log_info "Processed $current_file of $file_count video files"
