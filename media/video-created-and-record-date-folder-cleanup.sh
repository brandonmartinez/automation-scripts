#!/usr/bin/env zsh

setopt +o nomatch

dir=$1
DEBUG=${DEBUG:-false}

archive_dir="$dir/_archive"
imported_dir="$dir/_imported"

echo "Creating archive ($archive_dir) and imported ($imported_dir) directories"
mkdir -p "$archive_dir"
mkdir -p "$imported_dir"

for file in $dir/*.{mp4,m4v,mpg,mov}
do
    if [ -f "$file" ]; then
        echo "Processing $file"
        ./CreatedAndRecordDateCleanup.sh $file $DEBUG
    fi
done
