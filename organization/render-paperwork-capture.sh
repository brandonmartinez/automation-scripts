#!/usr/bin/env zsh
# render-capture.sh — Email → Paperwork capture renderer (Phase 2)
#
# Deterministic renderer. The AGENT fetches each Gmail message via the Google MCP
# and writes per-message staging artifacts; THIS script reads those artifacts plus
# canonical metadata from candidates.db and produces archive PDFs in the holding
# bucket.
#
# Canonical render = HYBRID: provenance banner (From/To/Date/Subject/Gmail-ID)
# concatenated ABOVE the sender's own HTML body → headless Edge → PDF. If the
# rendered text-layer char count falls below --min-chars, OR the plaintext body.txt
# is substantially richer than the HTML render (≥ --rich-ratio ×, default 1.5 —
# catches image-heavy senders like DTE that lay values out as inline images that
# don't survive headless HTML→PDF), automatically FALL BACK to plaintext-in-shell
# (banner + <pre>body.txt</pre>). Banner is injected by FILE CONCATENATION, never
# perl/shell interpolation.
#
# Staging layout (written by the agent):  <staging>/<msgid>/
#     body.html            cleaned sender HTML  (trailing {"result":…} JSON stripped)
#     body.txt             plaintext body       (fallback source)
#     meta.env             optional  KEY=VALUE:  TO=…            (banner enrichment)
#     _source/*.pdf        original attachments (Lane 1 companions)
#
# Metadata source of truth = candidates.db (date_raw, sender, subject, lane,
# sender_label). meta.env only enriches the banner (To:).
#
# Usage:
#   render-capture.sh [options] [msgid ...]
#     (no msgids) → process every staging/<msgid> dir not already in the ledger
#   Options:
#     --staging DIR   per-message staging root         (default: <script>/staging)
#     --db FILE       candidates.db                     (default: <script>/../discovery/candidates.db)
#     --out DIR       intake holding bucket             (default: <script>/_preview_intake)
#     --pending DIR   Lane-3 portal pointers            (default: <out>/_Pending Retrieval)
#     --ledger FILE   idempotent capture ledger         (default: <out>/capture-ledger.psv)
#     --min-chars N   hybrid text-layer floor           (default: 150)
#     --rich-ratio X  plaintext-richer trigger multiple  (default: 1.5)
#     --force         re-render even if msgid in ledger
#     --list          list what WOULD be rendered, do nothing

set -o errexit -o nounset -o pipefail

# --- locate repo utilities ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"

EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

# --- defaults -------------------------------------------------------------------
STAGING_DIR="$SCRIPT_DIR/staging"
DB="$SCRIPT_DIR/../discovery/candidates.db"
OUT_DIR="$SCRIPT_DIR/_preview_intake"
PENDING_DIR=""
LEDGER=""
MIN_CHARS=150
RICH_RATIO_X10=15   # plaintext "richer-source" trigger: body.txt ≥ 1.5× the HTML render's text layer
FORCE=0
LIST_ONLY=0
typeset -a MSGIDS=()

# --- sender alias map (brand normalization) -------------------------------------
typeset -A SENDER_ALIASES=(
  "[DTE EBILL EMAIL]"                                  "DTE Energy"
  "DTE EBILL EMAIL"                                    "DTE Energy"
  "PIXELLOT US, INC"                                   "Pixellot"
  "Synchrony for your MyLowe's Rewards Credit Card"    "Synchrony"
  "Microsoft 401(k) Plan Customer Service Center"      "Microsoft 401k"
  "<noreply@safelite.com>"                             "Safelite"
  "information@safeharborcu.org"                        "Safe Harbor Credit Union"
  "Copilot Money, Inc."                                "Copilot Money"
  "SoundCloud Transactions"                            "SoundCloud"
  "me@brandonmartinez.com"                             "Brandon Martinez"
)

# --- arg parse ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging)   STAGING_DIR="$2"; shift 2 ;;
    --db)        DB="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    --pending)   PENDING_DIR="$2"; shift 2 ;;
    --ledger)    LEDGER="$2"; shift 2 ;;
    --min-chars) MIN_CHARS="$2"; shift 2 ;;
    --rich-ratio) RICH_RATIO_X10="$(command python3 -c "print(int(round(float('$2')*10)))" 2>/dev/null || echo 15)"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do MSGIDS+="$1"; shift; done ;;
    -*) log_error "Unknown option: $1"; exit 2 ;;
    *)  MSGIDS+="$1"; shift ;;
  esac
done
: "${PENDING_DIR:=$OUT_DIR/_Pending Retrieval}"
: "${LEDGER:=$OUT_DIR/capture-ledger.psv}"

# --- html escape (order matters: & first) ---------------------------------------
html_escape() {
  local s="$1"
  s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}
  print -r -- "$s"
}

# --- filesystem-safe (single line, unsafe chars → space, collapse, trim, cap) ----
fs_safe() {
  local s="$1" cap="${2:-70}"
  s=${s//[$'\n\t\r']/ }
  s=${s//[\/\\:\*\?\"<>|]/ }
  s="$(print -r -- "$s" | command tr -s ' ')"
  s="${s## }"; s="${s%% }"
  [[ ${#s} -gt $cap ]] && s="${s[1,$cap]}"
  s="${s%% }"; s="${s%-}"; s="${s%% }"
  print -r -- "$s"
}

# --- sender label → clean brand -------------------------------------------------
sanitize_sender() {
  local raw="$1" clean
  if [[ -n "${SENDER_ALIASES[$raw]:-}" ]]; then
    print -r -- "${SENDER_ALIASES[$raw]}"; return
  fi
  clean="$raw"
  clean=${clean//[\[\]\"]/}                 # strip brackets & quotes
  if [[ "$clean" == *"<"*">"* ]]; then      # "Name <addr>" → Name
    clean="${clean%%<*}"
  elif [[ "$clean" == *"@"* && "$clean" != *" "* ]]; then
    clean="${clean%%@*}"                     # bare address → local part
  fi
  fs_safe "$clean" 40
}

# --- readable date from RFC-2822 date_raw ---------------------------------------
clean_date() {                               # → YYYY-MM-DD (fallback: 0000-00-00)
  local raw="${1%% \(*}" out
  out="$(command date -d "$raw" +%F 2>/dev/null)" || out=""
  [[ -z "$out" ]] && out="0000-00-00"
  print -r -- "$out"
}
pretty_date() {                              # human banner date, else the raw string
  local raw="${1%% \(*}" out
  out="$(command date -d "$raw" '+%A, %B %-d, %Y' 2>/dev/null)" || out="$1"
  print -r -- "$out"
}

# --- html shell parts -----------------------------------------------------------
emit_head() {
  cat <<'HEAD'
<!doctype html><html><head><meta charset="utf-8"><style>
  @page { size: Letter; margin: 0.75in; }
  * { box-sizing: border-box; }
  body { font-family:-apple-system,"Helvetica Neue",Arial,sans-serif; color:#1a1a1a; font-size:12px; line-height:1.5; margin:0; }
  .banner { border:1px solid #d0d5dd; border-radius:8px; overflow:hidden; margin-bottom:20px; }
  .banner .bar { background:#0b5cad; color:#fff; padding:8px 14px; font-weight:600; font-size:13px; letter-spacing:.02em; }
  .banner table { width:100%; border-collapse:collapse; }
  .banner td { padding:6px 14px; vertical-align:top; border-top:1px solid #eef0f3; }
  .banner td.k { width:110px; color:#667085; font-weight:600; text-transform:uppercase; font-size:10px; letter-spacing:.04em; }
  .banner td.v { color:#101828; word-break:break-word; }
  h1.subject { font-size:16px; margin:0 0 14px; color:#101828; }
  .ptxt { white-space:pre-wrap; word-break:break-word; font-size:12.5px; font-family:-apple-system,"Helvetica Neue",Arial,sans-serif; margin:0; }
  .footer { margin-top:26px; padding-top:10px; border-top:1px solid #e4e7ec; color:#98a2b3; font-size:9.5px; }
</style></head><body>
HEAD
}

# build the provenance banner fragment to a file (concat, never interpolation)
emit_banner() {                              # from to date subject gmailid  → stdout
  local from="$(html_escape "$1")" to="$(html_escape "$2")"
  local date="$(html_escape "$3")" subject="$(html_escape "$4")" gid="$(html_escape "$5")"
  print -r -- '<div class="banner"><div class="bar">CAPTURED EMAIL · PAPERWORK ARCHIVE</div><table>'
  print -r -- "<tr><td class=\"k\">From</td><td class=\"v\">${from}</td></tr>"
  [[ -n "$2" ]] && print -r -- "<tr><td class=\"k\">To</td><td class=\"v\">${to}</td></tr>"
  print -r -- "<tr><td class=\"k\">Date</td><td class=\"v\">${date}</td></tr>"
  print -r -- "<tr><td class=\"k\">Subject</td><td class=\"v\">${subject}</td></tr>"
  print -r -- "<tr><td class=\"k\">Gmail ID</td><td class=\"v\">${gid}</td></tr>"
  print -r -- '</table></div>'
}
emit_footer() {                              # mode
  local mode="$1" today="$(command date +%F)"
  print -r -- "<div class=\"footer\">Captured from Gmail on ${today} · ${mode} render (text-layer guaranteed) · Metadata source: candidates.db</div></body></html>"
}

# --- Edge render (isolated profile; slow — may exceed 30s) -----------------------
EDGE_PROFILE=""
edge_render() {                              # html_path pdf_path  (polls size-stability, reaps early)
  local html="$1" pdf="$2" i last=-1 cur=0 stable=0
  command rm -f "$pdf"
  "$EDGE" --headless --disable-gpu --no-pdf-header-footer \
    --virtual-time-budget=8000 \
    --user-data-dir="$EDGE_PROFILE" \
    --print-to-pdf="$pdf" "file://$html" >/dev/null 2>&1 &
  local epid=$!
  for i in $(seq 1 45); do
    kill -0 "$epid" 2>/dev/null || break            # Edge exited on its own
    if [[ -s "$pdf" ]]; then
      cur="$(command stat -c%s "$pdf" 2>/dev/null || print 0)"
      if [[ "$cur" == "$last" ]]; then
        stable=$((stable + 1))
        (( stable >= 3 )) && break                  # size unchanged 3s → write complete
      else
        stable=0
      fi
      last="$cur"
    fi
    sleep 1
  done
  kill "$epid" 2>/dev/null || true                  # reap the hang-on-exit process
  sleep 1
  kill -0 "$epid" 2>/dev/null && kill -9 "$epid" 2>/dev/null
  wait "$epid" 2>/dev/null || true
}
text_chars() {                               # pdf → char count of collapsed text layer
  local n
  n="$(command pdftotext "$1" - 2>/dev/null | command tr -s ' \n' ' ' | command wc -c | command tr -d ' ')" || n=0
  print -r -- "${n:-0}"
}

# --- ledger helpers -------------------------------------------------------------
in_ledger() {                                # msgid → 0 if present
  [[ -f "$LEDGER" ]] || return 1
  command grep -q "^$1|" "$LEDGER"
}
append_ledger() {                            # msgid lane mode outfile
  print -r -- "$1|$(command date +%FT%T)|$2|$3|$4" >>"$LEDGER"
}
# collision-free output path: same-sender/same-day duplicate emails (distinct msgids)
# can produce an identical "date - brand - subject" base. If the clean path is already
# taken on disk by a different message this run, disambiguate with a short msgid fragment
# (msgid is globally unique → guarantees no lost capture). Clean names stay clean.
resolve_outfile() {                          # dir base msgid → prints unique pdf path
  local dir="$1" base="$2" mid="$3" cand="$1/$2.pdf"
  [[ -e "$cand" ]] && cand="$1/$2 (${mid[-6,-1]}).pdf"
  print -r -- "$cand"
}

# ================================================================================
log_header "render-capture"
[[ -x "$EDGE" ]] || { log_error "Edge not found: $EDGE"; exit 1; }
[[ -f "$DB" ]]   || { log_error "DB not found: $DB"; exit 1; }
mkdir -p "$OUT_DIR" "$PENDING_DIR" "$OUT_DIR/_source"
EDGE_PROFILE="$(command mktemp -d)"
trap '[[ -n "$EDGE_PROFILE" && -d "$EDGE_PROFILE" ]] && rm -rf "$EDGE_PROFILE"' EXIT

# resolve work set
if [[ ${#MSGIDS} -eq 0 ]]; then
  for d in "$STAGING_DIR"/*(/N); do MSGIDS+="${d:t}"; done
fi
[[ ${#MSGIDS} -eq 0 ]] && { log_warn "No staging dirs / msgids to process under $STAGING_DIR"; exit 0; }
log_info "Work set: ${#MSGIDS} message(s) · out=$OUT_DIR · min-chars=$MIN_CHARS"

typeset -i n_done=0 n_skip=0 n_fail=0

for msgid in "${MSGIDS[@]}"; do
  stage="$STAGING_DIR/$msgid"
  if [[ ! -d "$stage" ]]; then
    log_warn "[$msgid] no staging dir — agent must fetch first; skipping"; ((++n_skip)); continue
  fi
  if (( ! FORCE )) && in_ledger "$msgid"; then
    log_info "[$msgid] already captured (ledger) — skipping"; ((++n_skip)); continue
  fi

  # --- metadata from DB (source of truth) ---
  row="$(command sqlite3 -separator '|' "$DB" \
        "SELECT date_raw,sender,subject,lane,sender_label FROM email_candidates WHERE msgid='$msgid';")" || row=""
  if [[ -z "$row" ]]; then
    log_error "[$msgid] not in DB; skipping"; ((++n_fail)); continue
  fi
  date_raw="${row%%|*}"; rest="${row#*|}"
  sender_hdr="${rest%%|*}"; rest="${rest#*|}"
  subject="${rest%%|*}"; rest="${rest#*|}"
  lane="${rest%%|*}"; sender_label="${rest#*|}"

  # optional banner enrichment
  to_addr=""
  [[ -f "$stage/meta.env" ]] && to_addr="$(command grep -E '^TO=' "$stage/meta.env" | head -1 | command sed 's/^TO=//')" || to_addr=""

  ymd="$(clean_date "$date_raw")"
  brand="$(sanitize_sender "$sender_label")"
  [[ -z "$brand" ]] && brand="$(sanitize_sender "$sender_hdr")"
  [[ -z "$brand" ]] && brand="unknown-sender"
  subj_slug="$(fs_safe "$subject" 70)"
  [[ -z "$subj_slug" ]] && subj_slug="no-subject"
  base="$ymd - $brand - $subj_slug"

  if (( LIST_ONLY )); then
    print -r -- "L$lane  $base"
    continue
  fi

  # =============================== LANE 3 — pointer note ========================
  if [[ "$lane" == "3" ]]; then
    tmp_html="$(command mktemp -t capnote.XXXXXX).html"
    { emit_head
      emit_banner "$sender_hdr" "$to_addr" "$(pretty_date "$date_raw")" "$subject" "$msgid"
      print -r -- "<h1 class=\"subject\">$(html_escape "$subject")</h1>"
      print -r -- '<p class="ptxt">Portal-only notification — the document lives behind a login and was not attached to the email. Retrieve from the sender portal and file the real document.</p>'
      if [[ -f "$stage/body.txt" ]]; then
        print -r -- '<hr><p class="ptxt">'; html_escape "$(command cat "$stage/body.txt")"; print -r -- '</p>'
      fi
      emit_footer "Pointer note"
    } >"$tmp_html"
    out_pdf="$(resolve_outfile "$PENDING_DIR" "$base" "$msgid")"
    edge_render "$tmp_html" "$out_pdf"
    rm -f "$tmp_html"
    if [[ -s "$out_pdf" ]]; then
      log_info "[$msgid] L3 pointer → ${out_pdf:t}"
      append_ledger "$msgid" 3 pointer "$out_pdf"; ((++n_done))
    else
      log_error "[$msgid] L3 render produced no PDF"; ((++n_fail))
    fi
    continue
  fi

  # =============================== LANE 1 / 2 — hybrid ==========================
  out_pdf="$(resolve_outfile "$OUT_DIR" "$base" "$msgid")"
  mode="hybrid"
  if [[ -f "$stage/body.html" ]]; then
    tmp_html="$(command mktemp -t caphyb.XXXXXX).html"
    { emit_head
      emit_banner "$sender_hdr" "$to_addr" "$(pretty_date "$date_raw")" "$subject" "$msgid"
      command cat "$stage/body.html"
      emit_footer "Hybrid"
    } >"$tmp_html"
    edge_render "$tmp_html" "$out_pdf"
    rm -f "$tmp_html"
  fi

  # fallback triggers: no html, empty pdf, thin text layer, OR body.txt substantially
  # richer than the HTML render (image-heavy senders like DTE lay values out as inline
  # images that don't survive headless HTML→PDF, leaving a labels-only shell).
  chars=0
  [[ -s "$out_pdf" ]] && chars="$(text_chars "$out_pdf")"
  txt_chars=0
  [[ -f "$stage/body.txt" ]] && txt_chars="$(command wc -c < "$stage/body.txt" | command tr -d ' ')"
  richer=0
  if (( chars > 0 && txt_chars > 0 )); then
    (( txt_chars * 10 >= chars * RICH_RATIO_X10 )) && richer=1
  fi
  if [[ ! -s "$out_pdf" || "$chars" -lt "$MIN_CHARS" ]] || (( richer )); then
    if [[ -f "$stage/body.txt" ]]; then
      if (( richer && chars >= MIN_CHARS )); then
        log_warn "[$msgid] richer plaintext (${txt_chars}b vs ${chars} html-chars, ≥$(( RICH_RATIO_X10 / 10 )).$(( RICH_RATIO_X10 % 10 ))×) — using plaintext shell"
        mode="plaintext-richer"
      else
        log_warn "[$msgid] hybrid thin (${chars} chars) — falling back to plaintext shell"
        mode="plaintext-fallback"
      fi
      tmp_html="$(command mktemp -t capfb.XXXXXX).html"
      { emit_head
        emit_banner "$sender_hdr" "$to_addr" "$(pretty_date "$date_raw")" "$subject" "$msgid"
        print -r -- "<h1 class=\"subject\">$(html_escape "$subject")</h1>"
        print -r -- '<p class="ptxt">'; html_escape "$(command cat "$stage/body.txt")"; print -r -- '</p>'
        emit_footer "Plaintext"
      } >"$tmp_html"
      edge_render "$tmp_html" "$out_pdf"
      rm -f "$tmp_html"
      [[ -s "$out_pdf" ]] && chars="$(text_chars "$out_pdf")"
    else
      log_error "[$msgid] hybrid thin and no body.txt to fall back to"
    fi
  fi

  if [[ ! -s "$out_pdf" ]]; then
    log_error "[$msgid] L$lane render FAILED (no PDF)"; ((++n_fail)); continue
  fi

  # Lane 1 companions: original attachments → _source/
  if [[ "$lane" == "1" && -d "$stage/_source" ]]; then
    for att in "$stage/_source/"*(.N); do
      cp -f "$att" "$OUT_DIR/_source/${out_pdf:t:r} — ${att:t}"
    done
  fi

  log_info "[$msgid] L$lane $mode (${chars} chars) → ${out_pdf:t}"
  append_ledger "$msgid" "$lane" "$mode" "$out_pdf"; ((++n_done))
done

log_divider "render-capture summary"
log_info "rendered=$n_done  skipped=$n_skip  failed=$n_fail  (ledger: $LEDGER)"
(( n_fail > 0 )) && exit 1 || exit 0
