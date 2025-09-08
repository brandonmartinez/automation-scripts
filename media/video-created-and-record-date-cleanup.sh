#!/usr/bin/env zsh

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "Video Created and Record Date Cleanup"

DEBUG=${DEBUG:-false}

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <video_file>"
    log_error "Please provide a video file to process"
    exit 1
fi

fullpath=$1

# Check if input file exists
if [[ ! -f "$fullpath" ]]; then
    log_error "Input file not found: $fullpath"
    exit 1
fi

log_info "Processing video file: $(basename "$fullpath")"

filename=$(basename $fullpath)
fileext="${filename##*.}"
filename="${filename%.*}"
dirname=$(dirname -- "$fullpath")
archive_dir="$dirname/_archive"
date=$(echo $filename | awk -F- '{print $1 $2 $3$4$5"."$6}')
date=$(echo $date | xargs)
formated_date=$(date -j -f "%Y%m%d%H%M.%S" "$date" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

# Validate date parsing
if [[ -z "$formated_date" ]]; then
    log_error "Failed to parse date from filename: $filename"
    log_error "Expected format: YYYYMMDD-HHMMSS"
    exit 1
fi

log_info "Parsed date from filename: $formated_date"

# Set initial values and log the date that
# will be written
##################################################

log_divider "Starting to process $(basename "$fullpath")"

log_info "The new date which will be written based on the filename is: $formated_date (sourced from $date)"

# Log the initial values in the file
##################################################

log_divider "Initial values for $(basename "$fullpath")"

log_info "The revised file created date is:"
birthtime=$(stat -f%B "$fullpath")
log_info "$(date -r $birthtime)"

log_info "The current video record dates are:"
exiftool -FileModifyDate -FileCreateDate -QuickTime:CreateDate "$fullpath" | while IFS= read -r line; do
    log_info "$line"
done

# Change the dates using touch and exiftool
##################################################

log_divider "Revising date to $date for $(basename "$fullpath")"

if [ "$DEBUG" = true ]; then
    if [ "$fileext" = "mpg" ]
    then
        log_debug "Command that would be executed: ffmpeg -i $fullpath ${fullpath%.*}.mp4 -y"
    fi

    log_debug "Command that would be executed: touch -mt $date $fullpath"
    log_debug "Command that would be executed: exiftool -FileModifyDate=\"$date\" -FileCreateDate=\"$date\" -QuickTime:CreateDate=\"$date\" $fullpath -overwrite_original"
else
    if [ "$fileext" = "mpg" ]
    then
        log_info "Converting $(basename "$fullpath") to mp4"
        if ffmpeg -i "$fullpath" "${fullpath%.*}.mp4" -y 2>/dev/null; then
            log_info "Successfully converted to mp4"

            # Create archive directory if it doesn't exist
            mkdir -p "$archive_dir"

            log_info "Moving original file to archive: $archive_dir"
            mv "$fullpath" "$archive_dir/$filename.$fileext"

            fullpath="${fullpath%.*}.mp4"
        else
            log_error "Failed to convert $fullpath to mp4"
            exit 1
        fi
    fi

    log_info "Updating file modification time"
    if touch -mt "$date" "$fullpath"; then
        log_info "Successfully updated file modification time"
    else
        log_error "Failed to update file modification time"
        exit 1
    fi

    log_info "Updating video metadata dates"
    if exiftool -FileModifyDate="$formated_date" -FileCreateDate="$formated_date" -QuickTime:CreateDate="$formated_date" "$fullpath" -overwrite_original >/dev/null 2>&1; then
        log_info "Successfully updated video metadata"
    else
        log_error "Failed to update video metadata"
        exit 1
    fi
fi

# Log the revised values in the file
##################################################

log_divider "Revised values for $(basename "$fullpath")"

log_info "The revised file created date is:"
birthtime=$(stat -f%B "$fullpath")
log_info "$(date -r $birthtime)"

log_info "The revised video record dates are:"
exiftool -FileModifyDate -FileCreateDate -QuickTime:CreateDate "$fullpath" | while IFS= read -r line; do
    log_info "$line"
done

# Exit
##################################################

log_info "Done processing $(basename "$fullpath")"
