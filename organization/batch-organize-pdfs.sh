#!/usr/bin/env zsh

# Project: automation-scripts - zsh shell scripts for macOS automation
# Description: Batch organize PDF files using OpenAI for intelligent categorization
# Shell: zsh (required)

# Set Shell Options (zsh-specific)
setopt ERR_EXIT        # Exit on error (equivalent to set -e)
setopt NO_UNSET        # Treat unset variables as an error (equivalent to set -u)
setopt PIPE_FAIL       # Fail if any command in pipeline fails (equivalent to set -o pipefail)
setopt EXTENDED_GLOB   # Enable extended globbing patterns
setopt NULL_GLOB       # Don't error on empty glob matches

if [[ "${TRACE-0}" == "1" ]]; then
    setopt XTRACE      # Enable command tracing (equivalent to set -x)
fi

# ============================================================================
# CONFIGURATION AND ENVIRONMENT SETUP
# ============================================================================

# Validate required environment
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# Configuration variables
readonly PAPERWORK_DIR="${PAPERWORK_DIR:-$HOME/Documents/Paperwork}"
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-DEBUG}"

# Validate input arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <source_directory> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --help             Show this help message" >&2
    echo "" >&2
    echo "Environment Variables:" >&2
    echo "  PAPERWORK_DIR      Destination directory (default: ~/Documents/Paperwork)" >&2
    echo "  LOG_LEVEL_NAME     Logging level (default: INFO)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 ~/Documents/Sort/OCR" >&2
    exit 1
fi

readonly SOURCE_DIR="$1"
shift

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            # Show help and exit
            exec "$0"
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
    shift
done

# Validate that the source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: '$SOURCE_DIR' does not exist or is not a directory" >&2
    exit 1
fi

# Ensure paperwork directory exists for logging
if [[ ! -d "$PAPERWORK_DIR" ]]; then
    mkdir -p "$PAPERWORK_DIR"
fi

# Initialize logging utility
export LOG_LEVEL=0
export LOG_FD=2
source "$SCRIPT_DIR/../utilities/logging.sh"
setup_script_logging
set_log_level "$LOG_LEVEL_NAME"

# Log header to mark new session start
log_header "batch-organize-pdfs.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print-statistics() {
    local total_found="$1"
    local total_succeeded="$2"
    local total_failed="$3"
    local total_skipped="$4"

    log_info "📊 BATCH PROCESSING STATISTICS"
    log_info "  📁 Total PDFs found: $total_found"
    log_info "  ✅ Successfully processed: $total_succeeded"
    log_info "  ❌ Failed to process: $total_failed"
    log_info "  ⏭️  Skipped: $total_skipped"

    # Calculate success rate, avoiding division by zero
    local total_processed=$((total_succeeded + total_failed))
    if [[ $total_processed -gt 0 ]]; then
        local success_rate=$((total_succeeded * 100 / total_processed))
    else
        local success_rate=0
    fi
    log_info "  📈 Success rate: ${success_rate}%"
}

process-single-pdf() {
    local pdf_file="$1"
    local pdf_basename=$(basename "$pdf_file")

    log_info "🔄 Processing: $pdf_basename"

    # Call the organize script with proper error handling
    if "$SCRIPT_DIR/organize-pdf-with-openai.sh" --move "$pdf_file"; then
        log_info "   ✅ Successfully organized: $pdf_basename"
        return 0
    else
        local exit_code=$?
        log_error "   ❌ Failed to organize: $pdf_basename (exit code: $exit_code)"
        return $exit_code
    fi
}

# ============================================================================
# MAIN PROCESSING LOGIC
# ============================================================================

log_info "🚀 Starting batch PDF organization"
log_info "📂 Source directory: $SOURCE_DIR"
log_info "📁 Destination directory: $PAPERWORK_DIR"

# Find all PDF files recursively using zsh globbing
log_info "🔍 Scanning for PDF files..."
PDF_FILES=()

# Use zsh's extended globbing for better performance and readability
for pdf_file in "$SOURCE_DIR"/**/*.pdf(N); do
    # Let organize-pdf-with-openai.sh handle validation - just check if it's a PDF file
    if [[ -r "$pdf_file" ]] && file "$pdf_file" | grep -q "PDF"; then
        PDF_FILES+=("$pdf_file")
    fi
done

TOTAL_FOUND=${#PDF_FILES}
log_info "📋 Found $TOTAL_FOUND PDF files to process"

if [[ $TOTAL_FOUND -eq 0 ]]; then
    log_warn "No PDF files found in $SOURCE_DIR"
    exit 0
fi

# Initialize counters
TOTAL_SUCCEEDED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

# Process PDFs sequentially using zsh array iteration
log_info "🔄 Starting sequential processing..."

# Use zsh array iteration with counter
for pdf_file in "${PDF_FILES[@]}"; do
    # Calculate progress (increment counter)
    (( CURRENT_INDEX = ${PDF_FILES[(I)$pdf_file]} ))
    progress=$(( CURRENT_INDEX * 100 / TOTAL_FOUND ))
    log_info "📈 Progress: $CURRENT_INDEX/$TOTAL_FOUND ($progress%)"

    # Process the PDF
    if process-single-pdf "$pdf_file"; then
        (( TOTAL_SUCCEEDED += 1 ))
    else
        (( TOTAL_FAILED += 1 ))
    fi
done

# ============================================================================
# COMPLETION AND SUMMARY
# ============================================================================

log_info "🎉 Batch processing completed!"
print-statistics "$TOTAL_FOUND" "$TOTAL_SUCCEEDED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"

if [[ $TOTAL_FAILED -gt 0 ]]; then
    log_warn "⚠️  Some files failed to process. Check the logs for details."
    log_info "💡 Common issues:"
    log_info "   • PDF files without proper timestamp in filename"
    log_info "   • Corrupted or password-protected PDFs"
    log_info "   • Network issues with OpenAI API"
    log_info "   • Insufficient disk space"
fi

log_info "📝 Detailed logs available at: $LOG_FILE"
log_divider "END OF BATCH PROCESSING"

# Exit with appropriate code
if [[ $TOTAL_FAILED -gt 0 ]]; then
    exit 2  # Some failures occurred
elif [[ $TOTAL_SUCCEEDED -eq 0 ]]; then
    exit 1  # No files were processed
else
    exit 0  # Success
fi
