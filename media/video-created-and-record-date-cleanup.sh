#!/usr/bin/env zsh

DEBUG=${DEBUG:-false}
fullpath=$1
filename=$(basename $fullpath)
fileext="${filename##*.}"
filename="${filename%.*}"
dirname=$(dirname -- "$fullpath")
archive_dir="$dirname/_archive"
date=$(echo $filename | awk -F- '{print $1 $2 $3$4$5"."$6}')
date=$(echo $date | xargs)
formated_date=$(date -j -f "%Y%m%d%H%M.%S" "$date" "+%Y-%m-%d %H:%M:%S")

log_message() {
    local light_gray=$(tput setaf 7)    # Change the color to light gray
    local reset=$(tput sgr0)             # Reset the color
    echo "${light_gray}${1}${reset}"
}

log_header() {
  RED=$(tput setaf 1)
  WHITE=$(tput setaf 7)
  RESET=$(tput sgr0)

  WRAPPED_TEXT=$(echo "$1" | fmt -w 100)

  echo ""
  echo -e "${RED}"$(printf '%0.s*' {1..100})"${RESET}"
  echo -e "${WHITE}${WRAPPED_TEXT}${RESET}"
  echo -e "${RED}"$(printf '%0.s*' {1..100})"${RESET}"
  echo ""
}

log_section() {
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  RESET=$(tput sgr0)

  WRAPPED_TEXT=$(echo "$1" | fmt -w 100)

  echo ""
  echo -e "${YELLOW}"$(printf '%0.s*' {1..100})"${RESET}"
  echo -e "${BLUE}${WRAPPED_TEXT}${RESET}"
  echo -e "${YELLOW}"$(printf '%0.s*' {1..100})"${RESET}"
  echo ""
}

# Set initial values and log the date that
# will be written
##################################################

log_header "Starting to process $fullpath"

echo "The new date which will be written based on the filename is: $formated_date (sourced from $date)"

# Log the initial values in the file
##################################################

log_section "Initial values for $fullpath"

echo "The revised file created date is:"
birthtime=$(stat -f%B $fullpath)
echo $(date -r $birthtime)

echo "The current video record dates are:"
exiftool -FileModifyDate -FileCreateDate -QuickTime:CreateDate $fullpath

# Change the dates using touch and exiftool
##################################################

log_section "Revising date to $date for $fullpath"

if [ "$DEBUG" = true ]; then
    if [ "$fileext" = "mpg" ]
    then
        log_message "Command that would be executed:\nffmpeg -i $fullpath ${fullpath%.*}.mp4 -y"
    fi

    log_message "Command that would be executed:\ntouch -mt $date $fullpath"
    echo ""

    log_message "Command that would be executed:\nexiftool -FileModifyDate=\"$date\" -FileCreateDate=\"$date\" -QuickTime:CreateDate=\"$date\" $fullpath -overwrite_original"
    echo ""
else
    if [ "$fileext" = "mpg" ]
    then
        log_message "Converting $fullpath to mp4"
        ffmpeg -i $fullpath ${fullpath%.*}.mp4 -y

        log_message "Moving $fullpath to $archive_dir"
        mv "$fullpath" "$archive_dir/$filename.$fileext"

        fullpath=${fullpath%.*}.mp4
    fi

    touch -mt $date "$fullpath"

    exiftool -FileModifyDate="$formated_date" -FileCreateDate="$formated_date" -QuickTime:CreateDate="$formated_date" "$fullpath" -overwrite_original
fi

# Log the revised values in the file
##################################################

log_section "Revised values for $fullpath"

log_message "The revised file created date is:"
birthtime=$(stat -f%B $fullpath)
log_message $(date -r $birthtime)

log_message "The revised video record dates are:"
exiftool -FileModifyDate -FileCreateDate -QuickTime:CreateDate $fullpath

# Exit
##################################################

log_message "Done processing $fullpath"
