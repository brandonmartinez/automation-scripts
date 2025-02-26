#!/usr/bin/env zsh

# Need to set a temp directory that we can read/write to
export TMPDIR="$HOME/.temp"
mkdir -p "$TMPDIR"

ocrmypdf -l eng --output-type pdf --redo-ocr --rotate-pages "$1" "$1"