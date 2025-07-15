#!/usr/bin/env zsh

# Lightweight logging utility for automation scripts
# Handles output redirection to ensure function outputs aren't corrupted

# Check if log file needs rotation and rotate if necessary
rotate_log_if_needed() {
    local log_file="$1"
    local max_size="${LOG_MAX_SIZE:-10485760}"  # 10MB default
    local max_backups="${LOG_MAX_BACKUPS:-5}"   # Keep 5 backup files

    # Check if log file exists and get its size
    if [[ -f "$log_file" ]]; then
        local file_size
        if command -v stat >/dev/null 2>&1; then
            # Use stat (works on both macOS and Linux)
            if stat -f%z "$log_file" >/dev/null 2>&1; then
                # macOS/BSD stat
                file_size=$(stat -f%z "$log_file" 2>/dev/null || echo 0)
            else
                # Linux/GNU stat
                file_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
            fi
        else
            # Fallback using wc if stat is not available
            file_size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
        fi

        # Rotate if file size exceeds maximum
        if [[ "$file_size" -gt "$max_size" ]]; then
            rotate_log_files "$log_file" "$max_backups"
        fi
    fi
}

# Rotate log files with numbered suffixes
rotate_log_files() {
    local log_file="$1"
    local max_backups="$2"

    # Move existing backup files up one number (e.g., .1 -> .2, .2 -> .3)
    local i=$max_backups
    while [[ $i -gt 1 ]]; do
        local current_backup="${log_file}.$((i-1))"
        local next_backup="${log_file}.${i}"

        if [[ -f "$current_backup" ]]; then
            mv "$current_backup" "$next_backup" 2>/dev/null
        fi

        ((i--))
    done

    # Move current log file to .1
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.1" 2>/dev/null

        # Create new empty log file with same permissions as original
        touch "$log_file"
        if [[ -f "${log_file}.1" ]]; then
            # Copy permissions from the backup file
            if command -v chmod >/dev/null 2>&1 && command -v stat >/dev/null 2>&1; then
                local perms
                if stat -f%Lp "${log_file}.1" >/dev/null 2>&1; then
                    # macOS/BSD stat
                    perms=$(stat -f%Lp "${log_file}.1" 2>/dev/null)
                else
                    # Linux/GNU stat
                    perms=$(stat -c%a "${log_file}.1" 2>/dev/null)
                fi
                [[ -n "$perms" ]] && chmod "$perms" "$log_file" 2>/dev/null
            fi
        fi

        # Log the rotation (but avoid infinite recursion by using stderr directly)
        printf "\033[0;32m[%s] INFO: Log file rotated: %s -> %s.1\033[0m\n" \
            "$(date '+%H:%M:%S')" \
            "$(basename "$log_file")" \
            "$(basename "$log_file")" >&2
    fi
}

# Only initialize if not already done
if [[ -z "${LOGGING_INITIALIZED:-}" ]]; then
    # Default log level (DEBUG=0, INFO=1, WARN=2, ERROR=3)
    export LOG_LEVEL=${LOG_LEVEL:-1}

    # Use stderr for all log messages to avoid corrupting function outputs
    export LOG_FD=${LOG_FD:-2}

    # Export LOG_FILE if set for consistency
    if [[ -n "${LOG_FILE:-}" ]]; then
        export LOG_FILE
    fi

    # Log rotation settings
    export LOG_MAX_SIZE=${LOG_MAX_SIZE:-10485760}  # 10MB default
    export LOG_MAX_BACKUPS=${LOG_MAX_BACKUPS:-5}   # Keep 5 backup files

    # Color codes for different log levels
    export LOG_COLOR_DEBUG="\033[0;36m"    # Cyan
    export LOG_COLOR_INFO="\033[0;32m"     # Green
    export LOG_COLOR_WARN="\033[0;33m"     # Yellow
    export LOG_COLOR_ERROR="\033[0;31m"    # Red
    export LOG_COLOR_RESET="\033[0m"       # Reset

    # Disable colors if NO_COLOR is set, but keep them for file logging
    if [[ -n "${NO_COLOR:-}" ]]; then
        LOG_COLOR_DEBUG=""
        LOG_COLOR_INFO=""
        LOG_COLOR_WARN=""
        LOG_COLOR_ERROR=""
        LOG_COLOR_RESET=""
    elif [[ ! -t $LOG_FD ]] && [[ -z "${LOG_FILE:-}" ]]; then
        # Only disable colors if not a terminal AND not using file logging
        LOG_COLOR_DEBUG=""
        LOG_COLOR_INFO=""
        LOG_COLOR_WARN=""
        LOG_COLOR_ERROR=""
        LOG_COLOR_RESET=""
    fi

    # Auto-setup file logging if LOG_FILE variable is set
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Create the directory if it doesn't exist
        local log_dir=$(dirname "$LOG_FILE")
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir"
        fi

        # Check if log rotation is needed
        rotate_log_if_needed "$LOG_FILE"

        # Save original file descriptors if not already saved
        if [[ -z "${LOG_ORIGINAL_FDS_SAVED:-}" ]]; then
            exec 3>&1 4>&2  # Save original stdout and stderr
            export LOG_ORIGINAL_FDS_SAVED=1
        fi

        # Redirect both stdout and stderr to log file while preserving terminal output
        exec 1> >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
        export LOG_FILE_PATH="$LOG_FILE"
    fi

    export LOGGING_INITIALIZED=1
fi

# Internal function to write log messages
_log_write() {
    local level=$1
    local level_name=$2
    local color=$3
    local message=$4

    # Ensure required variables are set with defaults
    local current_log_level=${LOG_LEVEL:-1}
    local current_log_fd=${LOG_FD:-2}
    local reset_color=${LOG_COLOR_RESET:-}

    if [[ $level -ge $current_log_level ]]; then
        printf "${color}[%s] %s: %s${reset_color}\n" \
            "$(date '+%H:%M:%S')" \
            "$level_name" \
            "$message" >&$current_log_fd
    fi
}

# Log confirmation if file logging was set up (after function is defined)
if [[ -n "${LOG_FILE_PATH:-}" ]] && [[ -n "${LOGGING_INITIALIZED:-}" ]]; then
    _log_write 1 "INFO" "${LOG_COLOR_INFO:-}" "Logging output redirected to: $LOG_FILE_PATH"
fi

# Public logging functions
log_debug() {
    _log_write 0 "DEBUG" "$LOG_COLOR_DEBUG" "$1"
}

log_info() {
    _log_write 1 "INFO" "$LOG_COLOR_INFO" "$1"
}

log_warn() {
    _log_write 2 "WARN" "$LOG_COLOR_WARN" "$1"
}

log_error() {
    _log_write 3 "ERROR" "$LOG_COLOR_ERROR" "$1"
}

# Set log level by name
set_log_level() {
    case "${1:-INFO}" in
        DEBUG) export LOG_LEVEL=0 ;;
        INFO)  export LOG_LEVEL=1 ;;
        WARN)  export LOG_LEVEL=2 ;;
        ERROR) export LOG_LEVEL=3 ;;
        *) log_warn "Unknown log level: $1, keeping current level" ;;
    esac
}

# Configure log rotation settings
set_log_rotation() {
    local max_size="${1:-10485760}"  # Default 10MB
    local max_backups="${2:-5}"      # Default 5 backup files

    # Validate max_size is a number
    if [[ ! "$max_size" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid max size: $max_size, keeping current setting"
        return 1
    fi

    # Validate max_backups is a number
    if [[ ! "$max_backups" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid max backups: $max_backups, keeping current setting"
        return 1
    fi

    export LOG_MAX_SIZE="$max_size"
    export LOG_MAX_BACKUPS="$max_backups"

    log_info "Log rotation configured: max_size=${max_size} bytes, max_backups=${max_backups}"
}

# Manually trigger log rotation
rotate_log_now() {
    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
        rotate_log_files "$LOG_FILE" "${LOG_MAX_BACKUPS:-5}"
        log_info "Manual log rotation completed"
    else
        log_warn "No active log file to rotate"
        return 1
    fi
}

# Enable/disable colors
set_log_colors() {
    case "${1:-auto}" in
        true|on|1)
            LOG_COLOR_DEBUG="\033[0;36m"
            LOG_COLOR_INFO="\033[0;32m"
            LOG_COLOR_WARN="\033[0;33m"
            LOG_COLOR_ERROR="\033[0;31m"
            LOG_COLOR_RESET="\033[0m"
            ;;
        false|off|0)
            LOG_COLOR_DEBUG=""
            LOG_COLOR_INFO=""
            LOG_COLOR_WARN=""
            LOG_COLOR_ERROR=""
            LOG_COLOR_RESET=""
            ;;
        auto)
            # Reapply the original color logic
            if [[ -n "${NO_COLOR:-}" ]]; then
                LOG_COLOR_DEBUG=""
                LOG_COLOR_INFO=""
                LOG_COLOR_WARN=""
                LOG_COLOR_ERROR=""
                LOG_COLOR_RESET=""
            elif [[ ! -t $LOG_FD ]] && [[ -z "${LOG_FILE:-}" ]]; then
                LOG_COLOR_DEBUG=""
                LOG_COLOR_INFO=""
                LOG_COLOR_WARN=""
                LOG_COLOR_ERROR=""
                LOG_COLOR_RESET=""
            else
                LOG_COLOR_DEBUG="\033[0;36m"
                LOG_COLOR_INFO="\033[0;32m"
                LOG_COLOR_WARN="\033[0;33m"
                LOG_COLOR_ERROR="\033[0;31m"
                LOG_COLOR_RESET="\033[0m"
            fi
            ;;
        *)
            log_warn "Unknown color setting: $1, use 'true', 'false', or 'auto'"
            ;;
    esac
}

# Visual divider for log sections
log_divider() {
    local message="${1:-}"
    local divider_char="${2:-*}"
    local divider_length=50

    # Create the divider line
    local divider_line=$(printf "%*s" $divider_length | tr ' ' "$divider_char")

    if [[ -n "$message" ]]; then
        # If message provided, center it in the divider
        local message_length=${#message}
        local padding=$(( (divider_length - message_length - 2) / 2 ))
        local left_padding=$(printf "%*s" $padding | tr ' ' "$divider_char")
        local right_padding=$(printf "%*s" $((divider_length - message_length - 2 - padding)) | tr ' ' "$divider_char")

        printf "${LOG_COLOR_INFO}%s %s %s${LOG_COLOR_RESET}\n" \
            "$left_padding" \
            "$message" \
            "$right_padding" >&$LOG_FD
    else
        # Just print the divider line
        printf "${LOG_COLOR_INFO}%s${LOG_COLOR_RESET}\n" "$divider_line" >&$LOG_FD
    fi
}

# Log header to mark the start of a new log session
log_header() {
    local script_name="${1:-$(basename "${0:-unknown}")}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local divider_char="="
    local divider_length=80

    # Check for log rotation if we have an active log file
    if [[ -n "${LOG_FILE:-}" ]]; then
        rotate_log_if_needed "$LOG_FILE"
    fi

    # Create the divider line
    local divider_line=$(printf "%*s" $divider_length | tr ' ' "$divider_char")

    # Bold formatting for better visibility when tailing logs
    local bold_start="\033[1m"
    local bold_end="\033[0m"

    # Combine with existing color for consistency
    local header_color="${LOG_COLOR_INFO}${bold_start}"
    local reset_color="${bold_end}${LOG_COLOR_RESET}"

    printf "\n${header_color}%s${reset_color}\n" "$divider_line" >&$LOG_FD
    printf "${header_color}NEW LOG SESSION: %s${reset_color}\n" "$script_name" >&$LOG_FD
    printf "${header_color}STARTED: %s${reset_color}\n" "$timestamp" >&$LOG_FD
    printf "${header_color}%s${reset_color}\n\n" "$divider_line" >&$LOG_FD
}

# Debug log API request/response with pretty printing
debug_log_api() {
    local type="$1"
    local data="$2"

    if [[ "$LOG_LEVEL" -le 0 ]]; then  # DEBUG level (0) or lower
        log_debug "=== $type ==="
        if command -v jq >/dev/null 2>&1 && echo "$data" | jq . >/dev/null 2>&1; then
            echo "$data" | jq . | while IFS= read -r line; do
                log_debug "$line"
            done
        else
            # Fallback if jq is not available or data is not JSON
            echo "$data" | while IFS= read -r line; do
                log_debug "$line"
            done
        fi
        log_debug "=== END $type ==="
    fi
}

# Restore original file descriptors
restore_log_redirection() {
    if [[ -n "${LOG_ORIGINAL_FDS_SAVED:-}" ]]; then
        exec 1>&3 2>&4  # Restore original stdout and stderr
        exec 3>&- 4>&-  # Close the saved file descriptors
        unset LOG_ORIGINAL_FDS_SAVED
        unset LOG_FILE_PATH
        log_info "Log redirection restored to original state"
    fi
}
