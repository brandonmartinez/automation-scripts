#!/usr/bin/env zsh

# Input file
inputFile="$1"

# Extract the subfolder name using parameter expansion
subFolder="${inputFile#*/3D Prints/}"
subFolder="${subFolder%/*/*/*}"

# Destination directory
dstDir="$HOME/Volumes/octopi-uploads/${subFolder}"

# Create the destination directory if it doesn't exist
mkdir -p "${dstDir}"

# Copy the file
cp "${inputFile}" "${dstDir}"
