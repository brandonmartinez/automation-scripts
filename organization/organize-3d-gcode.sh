#!/usr/bin/env zsh

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "3D G-code Organization"

# Input file
inputFile="$1"

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <gcode_file>"
    log_error "Please provide a G-code file to organize"
    exit 1
fi

# Check if input file exists
if [[ ! -f "$inputFile" ]]; then
    log_error "Input file not found: $inputFile"
    exit 1
fi

log_info "Organizing G-code file: $(basename "$inputFile")"

# Extract the subfolder name using parameter expansion
subFolder="${inputFile#*/3D Prints/}"
subFolder="${subFolder%/*/*/*}"

log_debug "Extracted subfolder: $subFolder"

# Destination directory
dstDir="$HOME/Volumes/octopi-uploads/${subFolder}"

log_info "Destination directory: $dstDir"

# Create the destination directory if it doesn't exist
log_debug "Creating destination directory if needed"
mkdir -p "${dstDir}"

# Copy the file
log_info "Copying file to destination"
if cp "${inputFile}" "${dstDir}"; then
    log_info "Successfully copied $(basename "$inputFile") to $dstDir"
else
    log_error "Failed to copy file to destination"
    exit 1
fi

log_info "G-code organization completed"
