#!/usr/bin/env zsh

# Set Shell Options
set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# ============================================================================
# CONFIGURATION AND ENVIRONMENT SETUP
# ============================================================================

# Validate required environment
PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"

# Configuration variables
readonly PAPERWORK_DIR="${PAPERWORK_DIR:-$HOME/Documents/Paperwork}"
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-INFO}"
readonly MAX_CONCURRENT="${MAX_CONCURRENT:-3}"  # Number of PDFs to process concurrently

# Validate input arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <source_directory> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --max-concurrent N Set maximum concurrent processes (default: 3)" >&2
    echo "  --help             Show this help message" >&2
    echo "" >&2
    echo "Environment Variables:" >&2
    echo "  PAPERWORK_DIR      Destination directory (default: ~/Documents/Paperwork)" >&2
    echo "  LOG_LEVEL_NAME     Logging level (default: INFO)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 ~/Documents/Sort/OCR" >&2
    echo "  $0 ~/Documents/Sort/OCR --max-concurrent 5" >&2
    exit 1
fi

readonly SOURCE_DIR="$1"
shift

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-concurrent)
            if [[ $# -lt 2 ]]; then
                echo "Error: --max-concurrent requires a number" >&2
                exit 1
            fi
            MAX_CONCURRENT="$2"
            shift
            ;;
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
export LOG_FILE="$PAPERWORK_DIR/batch-organize-logfile.txt"
source "$SCRIPT_DIR/../utilities/logging.sh"
set_log_level "$LOG_LEVEL_NAME"

# Log header to mark new session start
log_header "batch-organize-pdfs.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print-statistics() {
    local total_found="$1"
    local total_processed="$2"
    local total_succeeded="$3"
    local total_failed="$4"
    local total_skipped="$5"

    log_info "📊 BATCH PROCESSING STATISTICS"
    log_info "  📁 Total PDFs found: $total_found"
    log_info "  ✅ Successfully processed: $total_succeeded"
    log_info "  ❌ Failed to process: $total_failed"
    log_info "  ⏭️  Skipped: $total_skipped"

    # Calculate success rate, avoiding division by zero
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
    if "$SCRIPT_DIR/organize-pdf-with-openai.sh" "$pdf_file"; then
        log_info "   ✅ Successfully organized: $pdf_basename"
        return 0
    else
        local exit_code=$?
        log_error "   ❌ Failed to organize: $pdf_basename (exit code: $exit_code)"
        return $exit_code
    fi
}

is-valid-pdf() {
    local pdf_file="$1"

    # Check if file exists and is readable
    if [[ ! -r "$pdf_file" ]]; then
        log_debug "Skipping unreadable file: $(basename "$pdf_file")"
        return 1
    fi

    # Check if filename contains timestamp (required by organize script)
    if ! echo "$(basename "$pdf_file")" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}[-T][0-9]{2}-[0-9]{2}-[0-9]{2}'; then
        log_debug "Skipping PDF without timestamp: $(basename "$pdf_file")"
        return 1
    fi

    # Basic PDF validation (check file header)
    if command -v file >/dev/null 2>&1; then
        if ! file "$pdf_file" | grep -q "PDF"; then
            log_debug "Skipping non-PDF file: $(basename "$pdf_file")"
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# MAIN PROCESSING LOGIC
# ============================================================================

log_info "🚀 Starting batch PDF organization"
log_info "📂 Source directory: $SOURCE_DIR"
log_info "📁 Destination directory: $PAPERWORK_DIR"
log_info "⚙️  Max concurrent processes: $MAX_CONCURRENT"

# Find all PDF files recursively
log_info "🔍 Scanning for PDF files..."
PDF_FILES=()
while IFS= read -r -d '' pdf_file; do
    if is-valid-pdf "$pdf_file"; then
        PDF_FILES+=("$pdf_file")
    fi
done < <(find "$SOURCE_DIR" -type f -iname "*.pdf" -print0 2>/dev/null)

TOTAL_FOUND=${#PDF_FILES[@]}
log_info "📋 Found $TOTAL_FOUND valid PDF files to process"

if [[ $TOTAL_FOUND -eq 0 ]]; then
    log_warn "No valid PDF files found in $SOURCE_DIR"
    log_info "Note: PDFs must have timestamp format YYYY-MM-DD[T]HH-MM-SS in filename"
    exit 0
fi

# Initialize counters
TOTAL_PROCESSED=0
TOTAL_SUCCEEDED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
CURRENT_JOBS=0

# Create temporary directory for tracking background jobs
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

# Process PDFs with concurrency control
log_info "🔄 Starting batch processing..."

for pdf_file in "${PDF_FILES[@]}"; do
    # Wait if we've reached the maximum number of concurrent jobs
    while [[ $CURRENT_JOBS -ge $MAX_CONCURRENT ]]; do
        # Check for completed jobs
        for job_file in "$TEMP_DIR"/*.job; do
            [[ -f "$job_file" ]] || continue
            local job_pid=$(basename "$job_file" .job)
            if ! kill -0 "$job_pid" 2>/dev/null; then
                # Job is complete, check exit status from status file
                if [[ -f "$TEMP_DIR/${job_pid}.status" ]]; then
                    local exit_status=$(cat "$TEMP_DIR/${job_pid}.status")
                    if [[ $exit_status -eq 0 ]]; then
                        ((TOTAL_SUCCEEDED++))
                    else
                        ((TOTAL_FAILED++))
                    fi
                    rm -f "$TEMP_DIR/${job_pid}.status"
                else
                    # No status file means job failed unexpectedly
                    ((TOTAL_FAILED++))
                fi
                ((TOTAL_PROCESSED++))
                ((CURRENT_JOBS--))
                rm -f "$job_file"
            fi
        done

        # Brief sleep to avoid busy waiting
        sleep 0.1
    done

    # Start processing this PDF in the background
    (
        process-single-pdf "$pdf_file"
        echo $? > "$TEMP_DIR/$$.status"
    ) &

    local job_pid=$!
    echo "$pdf_file" > "$TEMP_DIR/${job_pid}.job"
    ((CURRENT_JOBS++))

    # Show progress
    if [[ $TOTAL_FOUND -gt 0 ]]; then
        local progress=$((TOTAL_PROCESSED * 100 / TOTAL_FOUND))
    else
        local progress=0
    fi
    log_info "📈 Progress: $TOTAL_PROCESSED/$TOTAL_FOUND ($progress%) - Active jobs: $CURRENT_JOBS"
done

# Wait for all remaining jobs to complete
log_info "⏳ Waiting for remaining jobs to complete..."
while [[ $CURRENT_JOBS -gt 0 ]]; do
    for job_file in "$TEMP_DIR"/*.job; do
        [[ -f "$job_file" ]] || continue
        local job_pid=$(basename "$job_file" .job)
        if ! kill -0 "$job_pid" 2>/dev/null; then
            # Job is complete, check exit status from status file
            if [[ -f "$TEMP_DIR/${job_pid}.status" ]]; then
                local exit_status=$(cat "$TEMP_DIR/${job_pid}.status")
                if [[ $exit_status -eq 0 ]]; then
                    ((TOTAL_SUCCEEDED++))
                else
                    ((TOTAL_FAILED++))
                fi
                rm -f "$TEMP_DIR/${job_pid}.status"
            else
                # No status file means job failed unexpectedly
                ((TOTAL_FAILED++))
            fi
            ((TOTAL_PROCESSED++))
            ((CURRENT_JOBS--))
            rm -f "$job_file"
        fi
    done
    sleep 0.1
done

# ============================================================================
# COMPLETION AND SUMMARY
# ============================================================================

log_info "🎉 Batch processing completed!"
print-statistics "$TOTAL_FOUND" "$TOTAL_PROCESSED" "$TOTAL_SUCCEEDED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"

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
