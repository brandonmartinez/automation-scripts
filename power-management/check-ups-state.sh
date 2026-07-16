#!/usr/bin/env zsh
# check-ups-state.sh — Power-loss guardian for the NAS.
#
# Polls the Mac's power sources (via `pmset -g ps`). When the machine
# transitions to running on the UPS battery (i.e. utility power was lost) it:
#   1. Stops any in-progress Time Machine backup (avoid a torn backup), and
#   2. Signals the NAS to power itself off gracefully before the UPS drains.
#
# Designed to run unattended, once a minute, from a launchd LaunchAgent. Two
# properties matter for an unattended per-minute job:
#   * It is IDEMPOTENT across an outage — the poweroff sequence fires on the
#     AC->UPS transition and then retries only until the NAS confirms it is
#     going down. It does NOT re-issue the whole sequence every single minute,
#     which previously produced a flood of failed-ssh mail once the NAS
#     had already powered off.
#   * It is QUIET on stdout/stderr — everything is routed through the repo
#     logging utility to a rotating log file. The LaunchAgent additionally
#     sends stdout/stderr to /dev/null (launchd, unlike cron, never mails).
#
# It also performs a lightweight health check: if no UPS device is visible to
# macOS at all, that means the UPS is NOT being monitored (USB dropped, etc.),
# so it logs a warning rather than silently reporting "on AC power".
#
# ---------------------------------------------------------------------------
# Install (launchd LaunchAgent — see com.brandonmartinez.check-ups-state.plist):
#   ln -sf "$HOME/src/automation-scripts/power-management/com.brandonmartinez.check-ups-state.plist" \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.check-ups-state.plist"
#   launchctl bootstrap gui/$(id -u) \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.check-ups-state.plist"
# Reload after edits:
#   launchctl bootout  gui/$(id -u)/com.brandonmartinez.check-ups-state 2>/dev/null || true
#   launchctl bootstrap gui/$(id -u) \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.check-ups-state.plist"
# Grant the launchd agent Full Disk Access if Time Machine control is blocked
# (System Settings > Privacy & Security > Full Disk Access).
#
# Configuration (environment overrides):
#   UPS_NAS_SSH_TARGET   ssh target for the NAS      (default: admin@192.168.18.100)
#   UPS_NAS_SSH_CMD      command run on the NAS       (default: poweroff)
#   UPS_MAX_POWEROFF_TRIES  cap on poweroff retries   (default: 5)
#   UPS_STOP_TIME_MACHINE   stop TM on outage (1/0)   (default: 1)
#   UPS_LOG_LEVEL           log verbosity              (default: INFO; use DEBUG by hand)
# ---------------------------------------------------------------------------

set -o errexit -o nounset -o pipefail

# --- locate repo utilities -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"
# Suppress the util's one-time "redirected to..." INFO notice: it would
# otherwise print on EVERY per-minute cron run and bury real power events.
# We momentarily raise the threshold to WARN across setup, then drop to the
# real operating level. Routine on-AC runs log at DEBUG (silent at INFO), so
# the log ends up containing only genuine power events + outage actions.
# Override the operating level with UPS_LOG_LEVEL (e.g. DEBUG when running by hand).
set_log_level WARN
setup_script_logging "check-ups-state"
set_log_level "${UPS_LOG_LEVEL:-INFO}"

# --- configuration ---------------------------------------------------------
NAS_SSH_TARGET="${UPS_NAS_SSH_TARGET:-admin@192.168.18.100}"
NAS_SSH_CMD="${UPS_NAS_SSH_CMD:-poweroff}"
MAX_POWEROFF_TRIES="${UPS_MAX_POWEROFF_TRIES:-5}"
STOP_TIME_MACHINE="${UPS_STOP_TIME_MACHINE:-1}"

# Persistent state so we can distinguish a *transition* from a *persisting*
# outage across independent cron invocations.
STATE_DIR="${UPS_STATE_DIR:-$HOME/Library/Application Support/automation-scripts/power-management}"
STATE_FILE="$STATE_DIR/power-state"
command mkdir -p "$STATE_DIR"

# ssh hardening for an unattended, network-may-be-degraded context:
#   BatchMode      never prompt (fail fast instead of hanging on a password)
#   ConnectTimeout bound the wait when the network is down mid-outage
#   -n             do not read from stdin (cron has none)
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# --- helpers ---------------------------------------------------------------

# Read the persisted state token (ac | ups-pending:<n> | ups-done). Defaults
# to "ac" on first run / missing file.
read_state() {
    if [[ -r "$STATE_FILE" ]]; then
        command cat "$STATE_FILE"
    else
        printf 'ac'
    fi
}

write_state() {
    printf '%s' "$1" >| "$STATE_FILE"
}

# Classify the current power situation from `pmset -g ps`.
# Sets two globals:
#   POWER_SOURCE   ac | ups | battery | unknown
#   UPS_PRESENT    1 if macOS can see a UPS/battery device, else 0
classify_power() {
    local ps_output
    # Guard the call: never let a transient pmset failure abort the whole run
    # under errexit — treat it as "unknown" instead.
    if ! ps_output="$(pmset -g ps 2>/dev/null)"; then
        POWER_SOURCE="unknown"
        UPS_PRESENT=0
        return 0
    fi

    local drawing_line
    drawing_line="$(printf '%s\n' "$ps_output" | command grep -m1 "Now drawing from" || true)"

    case "$drawing_line" in
    *"'UPS Power'"*) POWER_SOURCE="ups" ;;
    *"'Battery Power'"*) POWER_SOURCE="battery" ;;
    *"'AC Power'"*) POWER_SOURCE="ac" ;;
    *) POWER_SOURCE="unknown" ;;
    esac

    # A device line with "present: true" means macOS is actually tracking a
    # UPS/battery. No such line => nothing to monitor.
    if printf '%s\n' "$ps_output" | command grep -qi "present:[[:space:]]*true"; then
        UPS_PRESENT=1
    else
        UPS_PRESENT=0
    fi
}

# Best-effort stop of any running Time Machine backup. Failures are logged,
# never propagated (we do not want TM state to abort the NAS poweroff).
stop_time_machine_backup() {
    if [[ "$STOP_TIME_MACHINE" != "1" ]]; then
        return 0
    fi
    log_info "🛑 Stopping any in-progress Time Machine backup"
    if command tmutil stopbackup 2>&1 | while IFS= read -r l; do log_debug "tmutil: $l"; done; then
        return 0
    fi
    log_warn "⚠️  tmutil stopbackup returned non-zero (continuing anyway)"
    return 0
}

# Attempt to signal the NAS to power off. Returns 0 on success, 1 on failure.
signal_nas_poweroff() {
    log_info "📡 Signaling NAS ($NAS_SSH_TARGET) to '$NAS_SSH_CMD'"
    if command ssh "${SSH_OPTS[@]}" "$NAS_SSH_TARGET" "$NAS_SSH_CMD" \
        2>&1 | while IFS= read -r l; do log_debug "ssh: $l"; done; then
        log_info "✅ NAS poweroff signal delivered"
        return 0
    fi
    log_warn "⚠️  Failed to reach NAS ($NAS_SSH_TARGET) — will retry on next run"
    return 1
}

# --- main ------------------------------------------------------------------

classify_power
prev_state="$(read_state)"

# Health check: a UPS that macOS can't see is a UPS we are NOT monitoring.
if [[ "$UPS_PRESENT" -eq 0 && "$POWER_SOURCE" != "ups" ]]; then
    if [[ "$prev_state" != "no-ups" ]]; then
        log_warn "⚠️  No UPS/battery device visible to macOS — UPS is not being monitored (check USB connection)"
        write_state "no-ups"
    else
        log_debug "UPS still not visible to macOS"
    fi
    exit 0
fi

case "$POWER_SOURCE" in
ups)
    # Running on battery => utility power is out. Drive the poweroff sequence,
    # but only escalate the whole sequence on the first detection; afterward
    # just retry the ssh signal until it lands (or we hit the retry cap).
    case "$prev_state" in
    ups-done)
        log_debug "🔋 Still on UPS power; NAS poweroff already confirmed, no action"
        ;;
    ups-pending:*)
        tries="${prev_state#ups-pending:}"
        [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
        if [[ "$tries" -ge "$MAX_POWEROFF_TRIES" ]]; then
            log_debug "🔋 Still on UPS power; poweroff retry cap ($MAX_POWEROFF_TRIES) reached, no further attempts"
        elif signal_nas_poweroff; then
            write_state "ups-done"
        else
            write_state "ups-pending:$((tries + 1))"
        fi
        ;;
    *)
        # Fresh AC -> UPS transition.
        log_warn "🔌 Utility power LOST — now running on UPS battery"
        stop_time_machine_backup
        if signal_nas_poweroff; then
            write_state "ups-done"
        else
            write_state "ups-pending:1"
        fi
        ;;
    esac
    ;;

ac | battery)
    # "battery" would only appear on a portable; treat AC/portable-battery as
    # "utility power OK" for the NAS-protection purpose.
    case "$prev_state" in
    ups-* )
        log_warn "🔌 Utility power RESTORED — back on ${POWER_SOURCE} power"
        ;;
    *)
        log_debug "🔌 On ${POWER_SOURCE} power, no action needed"
        ;;
    esac
    write_state "ac"
    ;;

unknown)
    log_warn "❓ Could not determine power source from pmset; taking no action"
    ;;
esac

exit 0
