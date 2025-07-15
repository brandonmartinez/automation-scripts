#!/usr/bin/env zsh

# Lightweight logging utility for automation scripts
# Handles output redirection to ensure function outputs aren't corrupted

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

    # Color codes for different log levels
    export LOG_COLOR_DEBUG="\033[0;36m"    # Cyan
    export LOG_COLOR_INFO="\033[0;32m"     # Green
    export LOG_COLOR_WARN="\033[0;33m"     # Yellow
    export LOG_COLOR_ERROR="\033[0;31m"    # Red
    export LOG_COLOR_RESET="\033[0m"       # Reset

    # Disable colors if not a terminal or NO_COLOR is set
    if [[ ! -t $LOG_FD ]] || [[ -n "${NO_COLOR:-}" ]]; then
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

# Enable/disable colors
set_log_colors() {
    if [[ "$1" == "true" ]] && [[ -t $LOG_FD ]]; then
        LOG_COLOR_DEBUG="\033[0;36m"
        LOG_COLOR_INFO="\033[0;32m"
        LOG_COLOR_WARN="\033[0;33m"
        LOG_COLOR_ERROR="\033[0;31m"
        LOG_COLOR_RESET="\033[0m"
    else
        LOG_COLOR_DEBUG=""
        LOG_COLOR_INFO=""
        LOG_COLOR_WARN=""
        LOG_COLOR_ERROR=""
        LOG_COLOR_RESET=""
    fi
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
