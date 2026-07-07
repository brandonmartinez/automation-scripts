#!/usr/bin/env zsh

# ============================================================================
# standardize-paperwork-backfill.sh
#
# Backfill/standardization driver for an existing Paperwork archive.
#
# It reuses the go-forward categorization engine (organize-pdf-with-openai.sh)
# in --dry-run mode to produce a *proposal* for every existing document:
# where it should live, what it should be named, its document type, the
# resolved date, an AI confidence score, and whether it still needs OCR.
#
# SAFETY MODEL (propose-then-apply):
#   Pass 1 (default)  -> report only. ZERO mutations to the archive. Every
#                        file is analyzed on a throwaway TEMP COPY, so the
#                        original is never touched (not even by OCR).
#   Pass 2 (--apply)  -> not yet enabled. Guarded so it cannot run until the
#                        Pass 1 report has been reviewed and apply logic ships.
#
# OUTPUT (per run, under a timestamped directory):
#   report.jsonl   one JSON object per file (source of truth)
#   report.csv     spreadsheet-friendly view derived from report.jsonl
#   ledger.jsonl   processed-path ledger for idempotent resume
#   engine.log     combined engine stdout/stderr for troubleshooting
# ============================================================================

set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
readonly ENGINE="$SCRIPT_DIR/organize-pdf-with-openai.sh"

source "$SCRIPT_DIR/../utilities/logging.sh"
setup_script_logging "standardize-paperwork-backfill"

# ----------------------------------------------------------------------------
# Configuration & defaults
# ----------------------------------------------------------------------------
readonly PAPERWORK_DIR="${PAPERWORK_DIR:-$HOME/Documents/Paperwork}"
readonly BACKFILL_BASE_DIR="${PAPERWORK_BACKFILL_DIR:-$PAPERWORK_DIR/_Backfill}"

# Folders (relative to PAPERWORK_DIR) excluded from the backfill entirely.
# - underscore-prefixed working dirs (_Needs Review, _Backfill, ...)
# - Cornerstone Baptist Church worship media (not paperwork; relocated elsewhere)
readonly -a EXCLUDE_REL_PATHS=(
    "Organizations/Cornerstone Baptist Church"
)

LIMIT=0                    # 0 = no limit
CATEGORY_FILTER=""         # restrict to a single top-level category
FORCE=0                    # reprocess files already in the ledger
APPLY=0                    # Pass 2 (guarded, not yet implemented)
RESUME_DIR=""              # reuse an existing run directory (append + resume)
BATCH_PAUSE="${BACKFILL_BATCH_PAUSE:-0}"  # seconds to sleep between files

usage() {
    cat >&2 <<'EOF'
Usage: standardize-paperwork-backfill.sh [options]

Pass 1 (default) analyzes every existing PDF on a throwaway temp copy and
writes a proposal report. It makes ZERO changes to the archive.

Options:
  --limit <N>          Process at most N files (0 = all). Default: 0
  --category <name>    Only process files under this top-level category
  --resume <dir>       Reuse an existing run dir; skip files already in ledger
  --force              Reprocess files even if present in the ledger
  --paperwork-dir <p>  Override archive root (default: ~/Documents/Paperwork)
  --pause <seconds>    Sleep between files (gentle throttling). Default: 0
  --apply              Pass 2 apply mode (NOT YET IMPLEMENTED - guarded)
  --help, -h           Show this help
EOF
}

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)
            [[ $# -ge 2 ]] || { echo "Error: --limit requires a value" >&2; exit 1; }
            LIMIT="$2"; shift 2 ;;
        --category)
            [[ $# -ge 2 ]] || { echo "Error: --category requires a value" >&2; exit 1; }
            CATEGORY_FILTER="$2"; shift 2 ;;
        --resume)
            [[ $# -ge 2 ]] || { echo "Error: --resume requires a path" >&2; exit 1; }
            RESUME_DIR="$2"; shift 2 ;;
        --paperwork-dir)
            [[ $# -ge 2 ]] || { echo "Error: --paperwork-dir requires a path" >&2; exit 1; }
            PAPERWORK_DIR_OVERRIDE="$2"; shift 2 ;;
        --pause)
            [[ $# -ge 2 ]] || { echo "Error: --pause requires a value" >&2; exit 1; }
            BATCH_PAUSE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --apply) APPLY=1; shift ;;
        --help | -h) usage; exit 0 ;;
        *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

[[ "$LIMIT" == <-> ]] || { echo "Error: --limit must be an integer" >&2; exit 1; }

if [[ $APPLY -eq 1 ]]; then
    log_error "Pass 2 (--apply) is not yet implemented."
    log_error "This tool currently runs report-only Pass 1. Review the report first."
    exit 2
fi

# --paperwork-dir override (PAPERWORK_DIR is readonly above; use a resolved var)
PAPERWORK_ROOT="${PAPERWORK_DIR_OVERRIDE:-$PAPERWORK_DIR}"
PAPERWORK_ROOT="$(cd "$PAPERWORK_ROOT" &>/dev/null && pwd || echo "$PAPERWORK_ROOT")"

if [[ ! -d "$PAPERWORK_ROOT" ]]; then
    log_error "Paperwork directory not found: $PAPERWORK_ROOT"
    exit 1
fi
if [[ ! -x "$ENGINE" ]]; then
    log_error "Categorization engine not found or not executable: $ENGINE"
    exit 1
fi
for tool in pdftotext ocrmypdf jq; do
    command -v "$tool" &>/dev/null || { log_error "Required tool missing: $tool"; exit 1; }
done

# ----------------------------------------------------------------------------
# Run directory setup
# ----------------------------------------------------------------------------
if [[ -n "$RESUME_DIR" ]]; then
    RUN_DIR="$RESUME_DIR"
    [[ -d "$RUN_DIR" ]] || { log_error "Resume dir not found: $RUN_DIR"; exit 1; }
else
    RUN_DIR="$BACKFILL_BASE_DIR/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$RUN_DIR"
fi
readonly RUN_DIR
readonly REPORT_JSONL="$RUN_DIR/report.jsonl"
readonly REPORT_CSV="$RUN_DIR/report.csv"
readonly LEDGER="$RUN_DIR/ledger.jsonl"
readonly ENGINE_LOG="$RUN_DIR/engine.log"
readonly TMP_ROOT="$RUN_DIR/tmp"
mkdir -p "$TMP_ROOT"
: >>"$REPORT_JSONL"
: >>"$LEDGER"
: >>"$ENGINE_LOG"

cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Return 0 if the PDF already has a usable embedded text layer.
has_text_layer() {
    local pdf="$1" sample
    sample=$(pdftotext -l 3 "$pdf" - 2>/dev/null | tr -d '[:space:]' || true)
    [[ ${#sample} -ge 20 ]]
}

# True if a file's path (relative to root) is under an excluded subtree.
is_excluded() {
    local rel="$1" ex
    [[ "$rel" == _* ]] && return 0
    [[ "$rel" == */_* ]] && return 0
    for ex in "${EXCLUDE_REL_PATHS[@]}"; do
        [[ "$rel" == "$ex"/* || "$rel" == "$ex" ]] && return 0
    done
    return 1
}

ledger_has() {
    local p="$1"
    grep -qF "\"path\":\"$p\"" "$LEDGER" 2>/dev/null
}

ledger_add() {
    local p="$1" st="$2"
    jq -cn --arg path "$p" --arg status "$st" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{path:$path, status:$status, at:$at}' >>"$LEDGER"
}

# Analyze a single original file on a temp copy; echo the state-JSON path.
# Sets globals: NEEDS_OCR (yes/no), OCR_STATUS (ok/failed/skipped)
analyze_one() {
    local orig="$1"
    local base work state
    base="$(basename "$orig")"
    work="$TMP_ROOT/${$}-${RANDOM}-$base"
    state="$TMP_ROOT/${$}-${RANDOM}-state.json"

    cp "$orig" "$work"
    touch -r "$orig" "$work" 2>/dev/null || true

    if has_text_layer "$work"; then
        NEEDS_OCR="no"; OCR_STATUS="skipped"
    else
        NEEDS_OCR="yes"
        if ocrmypdf --skip-text -l eng --output-type pdf --rotate-pages \
            "$work" "$work.ocr" >>"$ENGINE_LOG" 2>&1; then
            mv "$work.ocr" "$work"
            touch -r "$orig" "$work" 2>/dev/null || true
            OCR_STATUS="ok"
        else
            rm -f "$work.ocr" 2>/dev/null || true
            OCR_STATUS="failed"
        fi
    fi

    {
        echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) $orig ====="
        "$ENGINE" --dry-run --state-file "$state" "$work"
    } >>"$ENGINE_LOG" 2>&1 || true

    rm -f "$work" 2>/dev/null || true
    # NOTE: Must NOT be called via $(...) — that runs in a subshell and would
    # discard the NEEDS_OCR/OCR_STATUS/STATE_PATH globals set above. Callers
    # invoke analyze_one as a plain statement and read STATE_PATH afterward.
    if [[ -s "$state" ]]; then STATE_PATH="$state"; else STATE_PATH=""; fi
}

# Build one report row (JSON) from a state file + original path facts.
emit_row() {
    local orig="$1" state="$2" needs_ocr="$3" ocr_status="$4"
    local rel_old cur_loc proposed proposed_rel proposed_dir proposed_name resolved_date action

    rel_old="${orig#$PAPERWORK_ROOT/}"
    cur_loc="$(dirname "$rel_old")"

    if [[ -n "$state" && -s "$state" ]]; then
        proposed=$(jq -r '.action.proposedPath // ""' "$state")
    else
        proposed=""
    fi

    if [[ -n "$proposed" ]]; then
        proposed_rel="${proposed#$PAPERWORK_ROOT/}"
        proposed_dir="$(dirname "$proposed_rel")"
        proposed_name="$(basename "$proposed")"
    else
        proposed_rel=""; proposed_dir=""; proposed_name=""
    fi

    resolved_date="${proposed_name:0:10}"
    [[ "$resolved_date" == <->-<->-<-> ]] || resolved_date=""

    local review_lane="no"
    [[ "$proposed_dir" == _* || "$proposed_dir" == *"/_"* ]] && review_lane="yes"

    if [[ -z "$proposed" ]]; then
        action="error"
    elif [[ "$review_lane" == "yes" ]]; then
        action="review"
    elif [[ "$proposed_dir" != "$cur_loc" ]]; then
        action="move"
    elif [[ "$proposed_name" != "$(basename "$orig")" ]]; then
        action="rename"
    else
        action="keep"
    fi

    local category sender department doc_type descriptor confidence summary
    if [[ -n "$state" && -s "$state" ]]; then
        category=$(jq -r '.plan.final.category // ""' "$state")
        sender=$(jq -r '.plan.final.sender // ""' "$state")
        department=$(jq -r '.plan.final.department // ""' "$state")
        doc_type=$(jq -r '.plan.analysis.documentType // ""' "$state")
        descriptor=$(jq -r '.plan.final.fileNameDescription // ""' "$state")
        confidence=$(jq -r '.plan.confidence // ""' "$state")
        summary=$(jq -r '.plan.final.summary // ""' "$state")
    else
        category=""; sender=""; department=""; doc_type=""; descriptor=""; confidence=""; summary=""
    fi

    jq -cn \
        --arg old_path "$orig" \
        --arg current_location "$cur_loc" \
        --arg proposed_location "$proposed_dir" \
        --arg proposed_filename "$proposed_name" \
        --arg action "$action" \
        --arg category "$category" \
        --arg sender "$sender" \
        --arg department "$department" \
        --arg date "$resolved_date" \
        --arg doc_type "$doc_type" \
        --arg descriptor "$descriptor" \
        --arg confidence "$confidence" \
        --arg needs_ocr "$needs_ocr" \
        --arg ocr_status "$ocr_status" \
        --arg review_lane "$review_lane" \
        --arg summary "$summary" \
        '{old_path:$old_path, current_location:$current_location,
          proposed_location:$proposed_location, proposed_filename:$proposed_filename,
          action:$action, category:$category, sender:$sender, department:$department,
          date:$date, doc_type:$doc_type, descriptor:$descriptor,
          confidence:$confidence, needs_ocr:$needs_ocr, ocr_status:$ocr_status,
          review_lane:$review_lane, summary:$summary}' >>"$REPORT_JSONL"
}

# Derive report.csv from report.jsonl (correct escaping via @csv).
write_csv() {
    local -a cols
    cols=(old_path current_location proposed_location proposed_filename action \
          category sender department date doc_type descriptor confidence \
          needs_ocr ocr_status review_lane summary)
    {
        print -r -- "${(j:,:)cols}"
        jq -r '[.old_path,.current_location,.proposed_location,.proposed_filename,
                .action,.category,.sender,.department,.date,.doc_type,.descriptor,
                .confidence,.needs_ocr,.ocr_status,.review_lane,.summary] | @csv' \
            "$REPORT_JSONL"
    } >"$REPORT_CSV"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
log_header "Paperwork standardization backfill - Pass 1 (report only)"
log_info "Archive:    $PAPERWORK_ROOT"
log_info "Run dir:    $RUN_DIR"
log_info "Limit:      $([[ $LIMIT -eq 0 ]] && echo 'all' || echo "$LIMIT")"
[[ -n "$CATEGORY_FILTER" ]] && log_info "Category:   $CATEGORY_FILTER"
[[ $FORCE -eq 1 ]] && log_info "Force:      reprocessing ledger entries"

scan_root="$PAPERWORK_ROOT"
[[ -n "$CATEGORY_FILTER" ]] && scan_root="$PAPERWORK_ROOT/$CATEGORY_FILTER"
if [[ ! -d "$scan_root" ]]; then
    log_error "Scan root does not exist: $scan_root"
    exit 1
fi

processed=0
skipped=0
errors=0

while IFS= read -r orig; do
    [[ -n "$orig" ]] || continue
    rel="${orig#$PAPERWORK_ROOT/}"
    if is_excluded "$rel"; then
        continue
    fi
    if [[ $FORCE -eq 0 ]] && ledger_has "$orig"; then
        skipped=$((skipped + 1))
        continue
    fi
    if [[ $LIMIT -gt 0 && $processed -ge $LIMIT ]]; then
        break
    fi

    processed=$((processed + 1))
    log_info "[$processed] $rel"

    NEEDS_OCR="no"; OCR_STATUS="skipped"; STATE_PATH=""
    analyze_one "$orig"
    state="$STATE_PATH"
    emit_row "$orig" "$state" "$NEEDS_OCR" "$OCR_STATUS"
    [[ -n "$state" ]] && rm -f "$state" 2>/dev/null || true

    if [[ -z "$state" ]]; then
        errors=$((errors + 1))
        ledger_add "$orig" "error"
        log_warn "    -> engine produced no plan (see engine.log)"
    else
        last_action=$(tail -n1 "$REPORT_JSONL" | jq -r '.action')
        last_conf=$(tail -n1 "$REPORT_JSONL" | jq -r '.confidence')
        log_info "    -> action=$last_action confidence=$last_conf ocr=$NEEDS_OCR"
        ledger_add "$orig" "analyzed"
    fi

    [[ "$BATCH_PAUSE" != "0" ]] && sleep "$BATCH_PAUSE"
done < <(find "$scan_root" -type f -iname '*.pdf' 2>/dev/null | sort)

write_csv

log_header "Backfill Pass 1 complete"
log_info "Analyzed:  $processed"
log_info "Skipped:   $skipped (already in ledger)"
log_info "Errors:    $errors"
log_info "Report:    $REPORT_CSV"
log_info "JSONL:     $REPORT_JSONL"
log_info "Ledger:    $LEDGER"
