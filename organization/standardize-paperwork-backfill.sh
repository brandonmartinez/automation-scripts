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
# - Radiant Church song charts / SongSelect sheet music (not paperwork)
readonly -a EXCLUDE_REL_PATHS=(
    "Organizations/Cornerstone Baptist Church"
    "Organizations/Radiant Church/Song Charts"
)

LIMIT=0                    # 0 = no limit
CATEGORY_FILTER=""         # restrict to a single top-level category
FORCE=0                    # reprocess files already in the ledger
APPLY=0                    # Pass 2 apply mode
RESUME_DIR=""              # reuse an existing run directory (append + resume)
BATCH_PAUSE="${BACKFILL_BATCH_PAUSE:-0}"  # seconds to sleep between files

# ---- Pass 2 (apply) configuration ----
BACKUP_DEST=""             # tarball backup destination (D1); required to mutate
SKIP_BACKUP=0              # bypass the backup gate (advanced / repeat runs)
ASSUME_YES=0              # actually mutate; without it apply is a dry-run plan
UNDO_MODE=0                # reverse a prior apply run (uses --resume dir)
RELOCATE_MODE=0            # one-time relocation of excluded worship media (D4)
OCR_MAX_MB="${BACKFILL_OCR_MAX_MB:-25}"          # skip OCR at/above this size (D2)
CONFIDENCE_MIN="${BACKFILL_CONFIDENCE_MIN:-0.75}" # below this -> review lane (D5)
RELOCATE_DEST="${BACKFILL_RELOCATE_DEST:-$HOME/Documents/OnSong/SongSelect}" # (D4)

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

Pass 2 (apply) options:
  --apply              Apply an approved report. REQUIRES --resume <run_dir>.
                       Without --yes this is a dry-run that only prints the plan.
  --yes                Actually mutate the filesystem (OCR/move/rename/tag).
  --backup-dest <p>    Tar the whole archive here before mutating (D1). Required
                       to mutate unless --skip-backup or a marker already exists.
  --skip-backup        Bypass the backup gate (advanced / repeat runs).
  --ocr-max-mb <N>     Skip OCR for files at/above this size in MB. Default: 25
  --confidence-min <f> Route rows below this confidence to review. Default: 0.75
  --undo               Reverse a prior apply run. REQUIRES --resume <run_dir>.
  --relocate-excluded  One-time move of excluded worship media out of Paperwork.
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
        --yes) ASSUME_YES=1; shift ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        --undo) UNDO_MODE=1; shift ;;
        --relocate-excluded) RELOCATE_MODE=1; shift ;;
        --backup-dest)
            [[ $# -ge 2 ]] || { echo "Error: --backup-dest requires a path" >&2; exit 1; }
            BACKUP_DEST="$2"; shift 2 ;;
        --ocr-max-mb)
            [[ $# -ge 2 ]] || { echo "Error: --ocr-max-mb requires a value" >&2; exit 1; }
            OCR_MAX_MB="$2"; shift 2 ;;
        --confidence-min)
            [[ $# -ge 2 ]] || { echo "Error: --confidence-min requires a value" >&2; exit 1; }
            CONFIDENCE_MIN="$2"; shift 2 ;;
        --help | -h) usage; exit 0 ;;
        *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

[[ "$LIMIT" == <-> ]] || { echo "Error: --limit must be an integer" >&2; exit 1; }
[[ "$OCR_MAX_MB" == <-> ]] || { echo "Error: --ocr-max-mb must be an integer" >&2; exit 1; }

if [[ ( $APPLY -eq 1 || $UNDO_MODE -eq 1 ) && -z "$RESUME_DIR" ]]; then
    echo "Error: --apply and --undo require --resume <run_dir> containing report.jsonl" >&2
    exit 1
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
# ---- Pass 2 (apply) artifacts, all under the same run dir ----
readonly APPLY_LOG="$RUN_DIR/apply.log"
readonly APPLY_LEDGER="$RUN_DIR/apply-ledger.jsonl"
readonly UNDO_LOG="$RUN_DIR/undo.jsonl"
readonly APPLY_REPORT_JSONL="$RUN_DIR/applied-report.jsonl"
readonly APPLY_REPORT_CSV="$RUN_DIR/applied-report.csv"
readonly BACKUP_MARKER="$RUN_DIR/.backup.json"
readonly DUP_INDEX="$RUN_DIR/dup-index.tsv"
readonly OCR_ORIG_DIR="$RUN_DIR/ocr-originals"
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

    # Depth guard (defense-in-depth): a valid destination is at most
    # Category/Sender/Department (3 segments). Anything deeper means the model
    # encoded a path fragment into a field (e.g. a court name as department);
    # route it to review rather than creating a malformed deep folder.
    if [[ -n "$proposed_dir" && "$review_lane" == "no" ]]; then
        local _depth
        _depth=$(print -r -- "$proposed_dir" | awk -F/ '{print NF}')
        [[ $_depth -gt 3 ]] && review_lane="yes"
    fi

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

# ============================================================================
# Pass 2 (apply) — turn an approved report into real filesystem changes.
# All mutations are gated behind --yes; without it every step is a printed plan.
# ============================================================================

# Normalize a folder/sender name for fuzzy comparison: lowercase, strip
# everything but [a-z0-9].
_norm_name() {
    local s="${1:l}"
    print -r -- "${s//[^a-z0-9]/}"
}

# True (0) if confidence ($1) is a number strictly below threshold ($2).
conf_below() {
    local c="$1" t="$2"
    [[ -n "$c" ]] || return 1
    awk -v a="$c" -v b="$t" 'BEGIN { exit (a+0 < b+0) ? 0 : 1 }'
}

# SHA-256 of a PDF's extracted text (content identity for dup detection).
text_sha() {
    local pdf="$1"
    pdftotext "$pdf" - 2>/dev/null | tr -d '[:space:]' | shasum -a 256 | awk '{print $1}'
}

apply_ledger_has() {
    grep -qF "\"old_path\":\"$1\"" "$APPLY_LEDGER" 2>/dev/null
}

apply_ledger_add() {
    jq -cn --arg old_path "$1" --arg result "$2" --arg detail "${3:-}" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{old_path:$old_path, result:$result, detail:$detail, at:$at}' >>"$APPLY_LEDGER"
}

# Append an applied-report row (one per processed file).
apply_report_add() {
    jq -cn --arg old_path "$1" --arg new_path "$2" --arg result "$3" \
        --arg ocr "$4" --arg dup_of "$5" \
        '{old_path:$old_path, new_path:$new_path, result:$result, ocr:$ocr, dup_of:$dup_of}' \
        >>"$APPLY_REPORT_JSONL"
}

# Record a reversible operation (moves, ocr backups) for --undo.
undo_add() {
    jq -cn --arg old_path "$1" --arg new_path "$2" --arg ocr_backup "${3:-}" \
        '{old_path:$old_path, new_path:$new_path, ocr_backup:$ocr_backup}' >>"$UNDO_LOG"
}

# Finder comment (kMDItemFinderComment) via Finder scripting. Guarded with a
# timeout: setting Finder comments needs Automation (TCC) permission, which is
# granted in the user's normal/Hazel environment but may hang elsewhere. On
# timeout we warn and continue rather than stalling the whole run.
set_finder_comment() {
    local file_path="$1" comment="$2"
    [[ -n "$comment" ]] || return 0
    local -a runner
    if command -v timeout &>/dev/null; then
        runner=(timeout 20 osascript)
    else
        runner=(osascript)
    fi
    "${runner[@]}" -e 'on run {f, c}' \
        -e 'tell app "Finder" to set comment of (POSIX file f as alias) to c' \
        -e end "$file_path" "$comment" >>"$APPLY_LOG" 2>&1 \
        || log_warn "    finder comment skipped (timeout/permission): ${file_path:t}"
}

# Finder tags (_kMDItemUserTags) via the `tag` CLI.
add_finder_tags() {
    local file_path="$1"; shift
    local -a tags; tags=()
    local t
    for t in "$@"; do
        [[ -n "$t" ]] && tags+=("$t")
    done
    [[ ${#tags} -gt 0 ]] || return 0
    tag --add "${(j:,:)tags}" "$file_path" >>"$APPLY_LOG" 2>&1 \
        || log_warn "    tag failed: ${file_path:t}"
}

# D2: should this file skip OCR (manual / guide / oversized reference)?
should_skip_ocr() {
    local orig="$1" category="$2" doc_type="$3"
    [[ "$category" == "Manuals" ]] && return 0
    local dt="${doc_type:l}"
    [[ "$dt" == *manual* || "$dt" == *guide* || "$dt" == *handbook* ]] && return 0
    local bytes mb
    bytes=$(wc -c < "$orig" 2>/dev/null | tr -d ' ' || echo 0)
    [[ "$bytes" == <-> ]] || bytes=0
    mb=$(( bytes / 1024 / 1024 ))
    [[ $mb -ge $OCR_MAX_MB ]] && return 0
    return 1
}

# OCR a file in place (--skip-text), keeping a pre-OCR copy under ocr-originals/.
# On success sets LAST_OCR_BACKUP to the backup path; returns non-zero on failure.
LAST_OCR_BACKUP=""
ocr_in_place() {
    local orig="$1"
    LAST_OCR_BACKUP=""
    local rel="${orig#$PAPERWORK_ROOT/}"
    local backup="$OCR_ORIG_DIR/$rel"
    mkdir -p "${backup:h}"
    cp "$orig" "$backup"
    local tmp="$TMP_ROOT/ocr-$$-$RANDOM.pdf"
    if ocrmypdf --skip-text -l eng --output-type pdf --rotate-pages \
        "$orig" "$tmp" >>"$APPLY_LOG" 2>&1; then
        mv "$tmp" "$orig"
        touch -r "$backup" "$orig" 2>/dev/null || true
        LAST_OCR_BACKUP="$backup"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    rm -f "$backup" 2>/dev/null || true
    return 1
}

# D3: given a category dir and proposed sender name, return an existing sibling
# folder whose name closely matches (exact, or one is a prefix of the other on
# the normalized form). Empty if no close match.
resolve_existing_sender() {
    local category_dir="$1" proposed="$2"
    [[ -d "$category_dir" && -n "$proposed" ]] || { print -r -- ""; return; }
    local norm_prop; norm_prop="$(_norm_name "$proposed")"
    [[ ${#norm_prop} -ge 3 ]] || { print -r -- ""; return; }
    local d name norm
    for d in "$category_dir"/*(/N); do
        name="${d:t}"
        [[ "$name" == "$proposed" ]] && { print -r -- ""; return; }  # already canonical
        norm="$(_norm_name "$name")"
        [[ ${#norm} -ge 3 ]] || continue
        if [[ "$norm" == "$norm_prop" \
           || "$norm" == "$norm_prop"* \
           || "$norm_prop" == "$norm"* ]]; then
            print -r -- "$name"; return
        fi
    done
    print -r -- ""
}

# Move src -> dest with collision handling. Echoes the final destination path,
# or "DUP" when an identical file already exists at dest.
safe_move() {
    local src="$1" dest="$2"
    mkdir -p "${dest:h}"
    if [[ -e "$dest" ]]; then
        if cmp -s "$src" "$dest"; then
            print -r -- "DUP"; return
        fi
        local base="${dest:r}" ext="${dest:e}" n=2 cand
        while :; do
            cand="$base ($n).$ext"
            [[ -e "$cand" ]] || break
            n=$((n + 1))
        done
        dest="$cand"
    fi
    mv "$src" "$dest"
    print -r -- "$dest"
}

# Quarantine a duplicate file into _Duplicates/, preserving its name.
quarantine_dup() {
    local src="$1"
    local qdir="$PAPERWORK_ROOT/_Duplicates"
    local dest; dest="$(safe_move "$src" "$qdir/${src:t}")"
    print -r -- "$dest"
}

# ----------------------------------------------------------------------------
# Backup gate (D1): tar the archive to --backup-dest, write a marker.
# ----------------------------------------------------------------------------
do_backup() {
    local dest="$1"
    mkdir -p "$dest" || { log_error "Cannot create backup dest: $dest"; return 1; }
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local tarball="$dest/paperwork-backup-$stamp.tar.gz"
    local parent="${PAPERWORK_ROOT:h}" leaf="${PAPERWORK_ROOT:t}"
    log_info "Backing up archive -> $tarball (this can take several minutes)..."
    if tar -czf "$tarball" --exclude="$leaf/_Backfill" -C "$parent" "$leaf"; then
        local sz; sz=$(wc -c < "$tarball" 2>/dev/null | tr -d ' ' || echo 0)
        [[ "$sz" == <-> ]] || sz=0
        jq -cn --arg tarball "$tarball" --arg archive "$PAPERWORK_ROOT" \
            --argjson bytes "${sz:-0}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{tarball:$tarball, archive:$archive, bytes:$bytes, at:$at}' >"$BACKUP_MARKER"
        log_info "Backup complete ($(( ${sz:-0} / 1024 / 1024 )) MB). Marker written."
        return 0
    fi
    log_error "Backup failed; refusing to mutate."
    return 1
}

# Enforce the backup gate before any mutation.
ensure_backup() {
    [[ -f "$BACKUP_MARKER" ]] && { log_info "Backup marker present; continuing."; return 0; }
    if [[ $SKIP_BACKUP -eq 1 ]]; then
        log_warn "--skip-backup set: proceeding WITHOUT a backup. You are on your own."
        return 0
    fi
    if [[ -n "$BACKUP_DEST" ]]; then
        do_backup "$BACKUP_DEST"; return $?
    fi
    log_error "No backup marker and no --backup-dest given."
    log_error "Provide --backup-dest <path> (recommended) or --skip-backup to proceed."
    return 1
}

# ----------------------------------------------------------------------------
# run_apply — Pass 2 main
# ----------------------------------------------------------------------------
run_apply() {
    : >>"$APPLY_LOG"; : >>"$APPLY_LEDGER"; : >>"$UNDO_LOG"
    : >"$APPLY_REPORT_JSONL"

    if [[ ! -s "$REPORT_JSONL" ]]; then
        log_error "No report.jsonl (or empty) in run dir: $RUN_DIR"
        return 1
    fi

    local total; total=$(grep -c '' "$REPORT_JSONL" 2>/dev/null || echo 0)
    log_header "Paperwork standardization backfill - Pass 2 (apply)"
    log_info "Archive:    $PAPERWORK_ROOT"
    log_info "Run dir:    $RUN_DIR"
    log_info "Report:     $REPORT_JSONL ($total rows)"
    log_info "OCR skip:   >= ${OCR_MAX_MB} MB or manual/guide/handbook"
    log_info "Review min: confidence < ${CONFIDENCE_MIN}"
    if [[ $ASSUME_YES -eq 1 ]]; then
        log_warn "MUTATE mode: filesystem WILL be changed."
        ensure_backup || return 1
    else
        log_info "DRY-RUN: printing the plan only. Re-run with --yes to apply."
    fi

    local applied=0 moved=0 renamed=0 ocrd=0 reviewed=0 dups=0 skipped=0 errs=0

    local old_path prop_loc prop_name action category sender department \
          date doc_type confidence needs_ocr review_lane summary
    while IFS=$'\x1f' read -r old_path prop_loc prop_name action category sender \
        department date doc_type confidence needs_ocr review_lane summary; do
        [[ -n "$old_path" ]] || continue

        if [[ $ASSUME_YES -eq 1 ]] && apply_ledger_has "$old_path"; then
            skipped=$((skipped + 1)); continue
        fi

        local rel="${old_path#$PAPERWORK_ROOT/}"

        # Re-validate the source still exists.
        if [[ ! -f "$old_path" ]]; then
            log_warn "[missing] $rel — skipping (not found)"
            [[ $ASSUME_YES -eq 1 ]] && apply_ledger_add "$old_path" "missing"
            skipped=$((skipped + 1)); continue
        fi

        # Excluded subtrees (worship media, working dirs) are handled by
        # --relocate-excluded, never by the standard apply.
        if is_excluded "$rel"; then
            log_info "[excluded] $rel — skipping (see --relocate-excluded)"
            [[ $ASSUME_YES -eq 1 ]] && apply_ledger_add "$old_path" "excluded"
            skipped=$((skipped + 1)); continue
        fi

        # Hard errors from Pass 1 (no plan): never touch.
        if [[ "$action" == "error" ]]; then
            log_warn "[error-row] $rel — skipping (Pass 1 produced no plan)"
            [[ $ASSUME_YES -eq 1 ]] && apply_ledger_add "$old_path" "error"
            errs=$((errs + 1)); continue
        fi

        # ---- Review lane (D5): move to _Needs Review/ + tag + comment ----
        local is_review=0
        if [[ "$review_lane" == "yes" || "$action" == "review" ]] \
            || conf_below "$confidence" "$CONFIDENCE_MIN"; then
            is_review=1
        fi

        if [[ $is_review -eq 1 ]]; then
            local rname="${prop_name:-${old_path:t}}"
            local rdest="$PAPERWORK_ROOT/_Needs Review/$rname"
            log_info "[review] $rel"
            log_info "         -> _Needs Review/$rname  (+tag 'Needs Review')"
            if [[ $ASSUME_YES -eq 1 ]]; then
                local final=""; final="$(safe_move "$old_path" "$rdest")"
                if [[ "$final" == "DUP" ]]; then
                    final="$(quarantine_dup "$old_path")"
                    apply_report_add "$old_path" "$final" "dup" "" ""
                    apply_ledger_add "$old_path" "dup"
                    dups=$((dups + 1)); continue
                fi
                undo_add "$old_path" "$final" ""
                set_finder_comment "$final" "$summary"
                add_finder_tags "$final" "Needs Review" "$category" "$sender"
                apply_report_add "$old_path" "$final" "review" "no" ""
                apply_ledger_add "$old_path" "review"
            fi
            reviewed=$((reviewed + 1)); continue
        fi

        # ---- Full apply ----
        # OCR (unless skipped by D2).
        local did_ocr="no" ocr_backup=""
        if [[ "$needs_ocr" == "yes" ]]; then
            if should_skip_ocr "$old_path" "$category" "$doc_type"; then
                did_ocr="skip"
                log_info "[ocr-skip] $rel (manual/large)"
            elif [[ $ASSUME_YES -eq 1 ]]; then
                if ocr_in_place "$old_path"; then
                    did_ocr="yes"; ocr_backup="$LAST_OCR_BACKUP"; ocrd=$((ocrd + 1))
                else
                    did_ocr="failed"; log_warn "    OCR failed: $rel"
                fi
            else
                did_ocr="plan"
            fi
        fi

        # Duplicate detection (content identity).
        if [[ $ASSUME_YES -eq 1 ]]; then
            local h="" existing=""
            h="$(text_sha "$old_path")"
            if [[ -n "$h" && -f "$DUP_INDEX" ]]; then
                # grep exits 1 on no-match; with pipefail that would trip
                # errexit, so swallow it and treat "no match" as empty.
                existing=$(grep -F "$h	" "$DUP_INDEX" 2>/dev/null | head -n1 | cut -f2-) \
                    || existing=""
            else
                existing=""
            fi
            if [[ -n "$existing" ]]; then
                local qdest=""; qdest="$(quarantine_dup "$old_path")"
                log_info "[dup] $rel -> _Duplicates/ (of ${existing:t})"
                undo_add "$old_path" "$qdest" "$ocr_backup"
                apply_report_add "$old_path" "$qdest" "dup" "$did_ocr" "$existing"
                apply_ledger_add "$old_path" "dup" "$existing"
                dups=$((dups + 1)); continue
            fi
        fi

        # Destination (with D3 sender auto-map).
        local dest_rel="$prop_loc" dest_name="$prop_name" eff_sender="$sender"
        if [[ -n "$category" && -n "$sender" ]]; then
            local existing_sender=""
            existing_sender="$(resolve_existing_sender "$PAPERWORK_ROOT/$category" "$sender")"
            if [[ -n "$existing_sender" && "$existing_sender" != "$sender" ]]; then
                local -a segs=("${(@s:/:)prop_loc}")
                if [[ ${#segs} -ge 2 && "${segs[2]}" == "$sender" ]]; then
                    segs[2]="$existing_sender"
                    dest_rel="${(j:/:)segs}"
                fi
                dest_name="${prop_name/ - $sender - / - $existing_sender - }"
                log_info "         sender remap: $sender -> $existing_sender (existing folder)"
                eff_sender="$existing_sender"
            fi
        fi

        local dest="$PAPERWORK_ROOT/$dest_rel/$dest_name"
        local dest_show="${dest#$PAPERWORK_ROOT/}"
        local op="rename"
        [[ "$dest_rel" != "$(dirname "$rel")" ]] && op="move"

        log_info "[$op] $rel"
        log_info "         -> $dest_show${did_ocr:+  (ocr=$did_ocr)}"

        if [[ $ASSUME_YES -eq 1 ]]; then
            local final=""; final="$(safe_move "$old_path" "$dest")"
            if [[ "$final" == "DUP" ]]; then
                final="$(quarantine_dup "$old_path")"
                undo_add "$old_path" "$final" "$ocr_backup"
                apply_report_add "$old_path" "$final" "dup" "$did_ocr" "$dest"
                apply_ledger_add "$old_path" "dup"
                dups=$((dups + 1)); continue
            fi
            # Record content hash for later dup detection.
            local kh=""; kh="$(text_sha "$final")"
            [[ -n "$kh" ]] && printf '%s\t%s\n' "$kh" "$final" >>"$DUP_INDEX"
            undo_add "$old_path" "$final" "$ocr_backup"

            # Metadata.
            set_finder_comment "$final" "$summary"
            local -a tagset=("$category" "$eff_sender")
            [[ -n "$doc_type" ]] && tagset+=("$doc_type")
            if [[ "$category" == "Taxes" || "${doc_type:l}" == *tax* ]] && [[ -n "$date" ]]; then
                tagset+=("Tax ${date:0:4}")
            fi
            add_finder_tags "$final" "${tagset[@]}"

            apply_report_add "$old_path" "$final" "$op" "$did_ocr" ""
            apply_ledger_add "$old_path" "$op"
        fi

        applied=$((applied + 1))
        [[ "$op" == "move" ]] && moved=$((moved + 1)) || renamed=$((renamed + 1))
        [[ "$BATCH_PAUSE" != "0" ]] && sleep "$BATCH_PAUSE"
    done < <(jq -r '[.old_path,.proposed_location,.proposed_filename,.action,
                     .category,.sender,.department,.date,.doc_type,.confidence,
                     .needs_ocr,.review_lane,.summary]
                    | map(gsub("[\n\r\u001f]";" ")) | join("\u001f")' "$REPORT_JSONL")

    # applied-report.csv
    if [[ -s "$APPLY_REPORT_JSONL" ]]; then
        {
            print -r -- "old_path,new_path,result,ocr,dup_of"
            jq -r '[.old_path,.new_path,.result,.ocr,.dup_of] | @csv' "$APPLY_REPORT_JSONL"
        } >"$APPLY_REPORT_CSV"
    fi

    log_header "Backfill Pass 2 $([[ $ASSUME_YES -eq 1 ]] && echo complete || echo '(dry-run) complete')"
    log_info "Applied:   $applied (move=$moved rename=$renamed)"
    log_info "OCR'd:     $ocrd"
    log_info "Review:    $reviewed"
    log_info "Dups:      $dups"
    log_info "Skipped:   $skipped"
    log_info "Errors:    $errs"
    [[ $ASSUME_YES -eq 1 ]] && log_info "Undo log:  $UNDO_LOG"
    [[ -f "$APPLY_REPORT_CSV" ]] && log_info "Report:    $APPLY_REPORT_CSV"
    [[ $ASSUME_YES -eq 0 ]] && log_warn "No changes made. Re-run with --yes (and --backup-dest) to apply."
    return 0
}

# ----------------------------------------------------------------------------
# run_undo — reverse a prior apply run using undo.jsonl (LIFO).
# ----------------------------------------------------------------------------
run_undo() {
    if [[ ! -s "$UNDO_LOG" ]]; then
        log_error "No undo log (or empty) in run dir: $RUN_DIR"
        return 1
    fi
    log_header "Reversing apply run: $RUN_DIR"
    if [[ $ASSUME_YES -eq 0 ]]; then
        log_info "DRY-RUN: would reverse $(grep -c '' "$UNDO_LOG") operations. Add --yes to run."
    fi
    local restored=0 failed=0
    local -a lines
    lines=("${(@f)$(cat "$UNDO_LOG")}")
    local i entry old_path new_path ocr_backup
    for (( i=${#lines}; i>=1; i-- )); do
        entry="${lines[i]}"
        [[ -n "$entry" ]] || continue
        old_path=$(jq -r '.old_path' <<<"$entry")
        new_path=$(jq -r '.new_path' <<<"$entry")
        ocr_backup=$(jq -r '.ocr_backup // ""' <<<"$entry")
        log_info "restore: ${new_path:t} -> ${old_path#$PAPERWORK_ROOT/}"
        if [[ $ASSUME_YES -eq 1 ]]; then
            if [[ -f "$new_path" ]]; then
                mkdir -p "${old_path:h}"
                if mv "$new_path" "$old_path" 2>>"$APPLY_LOG"; then
                    restored=$((restored + 1))
                else
                    log_warn "    move-back failed"; failed=$((failed + 1)); continue
                fi
            elif [[ ! -f "$old_path" ]]; then
                log_warn "    neither new nor old path present; skipping"; failed=$((failed + 1)); continue
            fi
            if [[ -n "$ocr_backup" && -f "$ocr_backup" ]]; then
                cp "$ocr_backup" "$old_path" 2>>"$APPLY_LOG" \
                    && log_info "    restored pre-OCR bytes"
            fi
        fi
    done
    log_header "Undo $([[ $ASSUME_YES -eq 1 ]] && echo complete || echo '(dry-run) complete')"
    log_info "Restored:  $restored"
    log_info "Failed:    $failed"
    [[ $ASSUME_YES -eq 0 ]] && log_warn "No changes made. Re-run with --yes to reverse."
    return 0
}

# ----------------------------------------------------------------------------
# run_relocate_excluded — one-time move of excluded worship media out of
# Paperwork into RELOCATE_DEST (D4).
# ----------------------------------------------------------------------------
run_relocate_excluded() {
    log_header "Relocate excluded worship media out of Paperwork"
    log_info "Destination: $RELOCATE_DEST"
    if [[ $ASSUME_YES -eq 0 ]]; then
        log_info "DRY-RUN: printing the plan only. Add --yes to move."
    fi
    local ex src count=0
    for ex in "${EXCLUDE_REL_PATHS[@]}"; do
        [[ "$ex" == _* ]] && continue
        src="$PAPERWORK_ROOT/$ex"
        [[ -d "$src" ]] || { log_info "skip (absent): $ex"; continue; }
        local n=""; n=$(find "$src" -type f 2>/dev/null | grep -c '' || echo 0)
        local dest="$RELOCATE_DEST/${ex:t}"
        log_info "move: $ex ($n files) -> ${dest/#$HOME/~}"
        if [[ $ASSUME_YES -eq 1 ]]; then
            mkdir -p "${dest:h}"
            if [[ -e "$dest" ]]; then
                # merge contents to avoid clobbering
                mkdir -p "$dest"
                if command -v rsync &>/dev/null; then
                    rsync -a "$src"/ "$dest"/ >>"$APPLY_LOG" 2>&1 && rm -rf "$src"
                else
                    cp -R "$src"/ "$dest"/ && rm -rf "$src"
                fi
            else
                mv "$src" "$dest" 2>>"$APPLY_LOG" || { log_warn "    move failed"; continue; }
            fi
            count=$((count + n))
        fi
    done
    log_header "Relocation $([[ $ASSUME_YES -eq 1 ]] && echo complete || echo '(dry-run) complete')"
    log_info "Files moved: $count"
    [[ $ASSUME_YES -eq 0 ]] && log_warn "No changes made. Re-run with --yes to relocate."
    return 0
}

# ----------------------------------------------------------------------------
# Dispatch: apply / undo / relocate short-circuit Pass 1.
# ----------------------------------------------------------------------------
if [[ $RELOCATE_MODE -eq 1 ]]; then run_relocate_excluded; exit $?; fi
if [[ $UNDO_MODE -eq 1 ]]; then run_undo; exit $?; fi
if [[ $APPLY -eq 1 ]]; then run_apply; exit $?; fi

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
