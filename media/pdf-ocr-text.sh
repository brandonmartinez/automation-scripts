#!/usr/bin/env zsh

# Get the script directory to load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

PATH="/opt/homebrew/bin/:$PATH"

# Set up logging to standard macOS location with module folder
setup_script_logging
log_header "PDF OCR Text Processing"

# Validate input arguments
if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
    log_error "Usage: $0 <pdf_file>"
    log_error "Please provide a PDF file to process"
    exit 1
fi

input_file="$1"

# Check if input file exists
if [[ ! -f "$input_file" ]]; then
    log_error "Input file not found: $input_file"
    exit 1
fi

# Check if input file is a PDF
if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
    log_warn "File does not have a PDF extension: $input_file"
    log_info "Proceeding anyway as ocrmypdf will validate the file format"
fi

log_info "Starting OCR processing for: $(basename "$input_file")"
log_info "Input file size: $(du -h "$input_file" | cut -f1)"

# Need to set a temp directory that we can read/write to
export TMPDIR="$HOME/.temp"
log_debug "Creating temp directory: $TMPDIR"
mkdir -p "$TMPDIR"

# Check if ocrmypdf is available
if ! command -v ocrmypdf >/dev/null 2>&1; then
    log_error "ocrmypdf command not found. Please install it first:"
    log_error "  brew install ocrmypdf"
    exit 1
fi

log_info "Running OCR with language: eng, output type: pdf, redo-ocr: true, rotate-pages: true"
log_debug "Command: ocrmypdf -l eng --output-type pdf --redo-ocr --rotate-pages \"$input_file\" \"$input_file\""

# Run ocrmypdf with error handling
if ocrmypdf -l eng --output-type pdf --redo-ocr --rotate-pages "$input_file" "$input_file"; then
    log_info "OCR processing completed successfully"
    log_info "Output file size: $(du -h "$input_file" | cut -f1)"
    log_info "Processed file: $input_file"
else
    exit_code=$?
    log_error "OCR processing failed with exit code: $exit_code"
    log_error "Check the file format and try again"
    exit $exit_code
fi

log_info "PDF OCR processing completed for: $(basename "$input_file")"
