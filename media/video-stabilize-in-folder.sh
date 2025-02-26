#!/bin/sh

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
FILE_PATH_FILTER="$1/*.@(mp4|mov|m4v)"

# Enable extended patterns and ignore casing
shopt -s extglob
shopt -s nocaseglob

# Loop through files
for file in $FILE_PATH_FILTER
do
    # If there are no files, break
    [ -f "$file" ] || break

    # Get path and filename components
    DIRNAME=$(dirname "$file")
    FILENAME=$(basename -- "$file")
    EXTENSION="${FILENAME##*.}"
    FILENAME="${FILENAME%.*}"

    # Build new filenames
    TRANSFORM_FILE="$DIRNAME/$FILENAME.trf"
    STABILIZED_FILE="$DIRNAME/$FILENAME-stabilized.$EXTENSION"

    # Get stabilization data
    echo "Creating stabilization data from $file"
    ffmpeg -i $file -vf vidstabdetect=result=$TRANSFORM_FILE -f null -

    # Transform the video and output to new file
    echo "Transforming $file with stabilization data to new file $STABILIZED_FILE"
    ffmpeg -i $file -vf vidstabtransform=input=$TRANSFORM_FILE $STABILIZED_FILE

    echo "Finished stabilizing $file to $STABILIZED_FILE"
done
