#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

if [[ "${TRACE-0}" == "1" ]]; then
	set -o xtrace
fi

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
readonly OUTPUT_DIR="${GUITAR_TAB_OUTPUT:-$HOME/Documents/Guitar Tabs}"
readonly LOG_LEVEL_NAME="${LOG_LEVEL_NAME:-INFO}"
readonly MODEL_NAME="${OPENAI_MODEL:-gpt-5.1}"

usage() {
	cat <<'USAGE'
Usage: organize-guitar-tabs.sh [--dry-run] <text-file>

Formats a raw lyrics/chords text file into OnSong-style tab output using OpenAI
and writes the result to $GUITAR_TAB_OUTPUT (or a default folder) with the name
"ARTIST - SONG.txt".

Options:
	--dry-run   Print the formatted tab to stdout only (no file writes)
	--debug-notes Print a list of model-described changes (does not alter tab)
USAGE
}

require_command() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Missing required command: $cmd" >&2
		exit 1
	fi
}

sanitize_component() {
	printf '%s' "$1" |
		tr -d '\r' |
		sed 's/[\/:*?"<>|]/-/g' |
		sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//' |
		tr -s ' '
}

build_request_body() {
	local input_text="$1"

	local system_prompt

	system_prompt=$(cat <<'PROMPT'
You are a formatter. Input is a raw guitar tab / chord+lyric text file for a
single song. Output a clean, refactored OnSong-style chart wrapped in JSON.

OUTPUT FORMAT (JSON ONLY)
- Return ONLY a single JSON object (no markdown, no code fences, no commentary).
- JSON must include at least these keys: "artist", "song_title",
	"formatted_tab". You may include an optional "debug_notes" array of strings
	describing the key cleanup/normalization steps you performed.
- "artist": normalized artist name (string).
- "song_title": normalized song title (string).
- "formatted_tab": the FULL OnSong text exactly as it should be written to the
	.tab file (string). Include newlines in the string via literal "\n".
DEBUG NOTES (OPTIONAL)
- If provided, "debug_notes" should be a concise list of changes such as
	consolidating duplicate choruses, moving chords above lyrics, normalizing
	headers/flow, bar-notation fixes, and section renames.

HARD REQUIREMENTS
- Plain text only inside formatted_tab. ASCII only (straight quotes, normal
  hyphens).
- Preserve song content; normalize formatting and spacing.
- Chords must be ABOVE lyrics (chords-over-lyrics). Do NOT leave inline chords.
- Instrumental chord runs use bar notation with pipes: "| G   Em7   | Cadd9  G D |".
- Produce a reduced chart: include each unique section once; use Flow for
  repetition.

TITLE + ARTIST NORMALIZATION
- Normalize title/artist using standard conventions; look up canonical if
  confidently possible. If not confident, keep best normalized input.
- If title and artist appear on a single line (e.g., "Song 123 by Artist X" or
	similar), split and normalize them into separate Title and Artist values.

HEADER FORMAT (inside formatted_tab)
1) Line 1: Song Title (normalized)
2) Line 2: Artist (normalized)
3) Metadata block (all fields required, one per line, blanks allowed):
   Key:
   Capo:
   Tempo:
   Time:
   Flow:
   Tuning:
   TransposedKey:
4) Two blank lines after metadata before the first song section.

TUNING RULES
- Tuning MUST be present. Default to "Standard" if unknown; use known non-
  standard if explicit/confident.

FLOW (REQUIRED)
- Flow MUST be present. Use compact tokens (Intro, V1, V2, PC, C1, C2, B,
  Solo, Outro, Tag). Represent repeats in Flow only.
- Small variation: note with parenthetical line before changed lines. Large
  variation: create distinct sections (e.g., Chorus 1 / Chorus 2) and reference
  accordingly.
- Check for repeated sections (esp. choruses/pre-choruses). If a later version
	is not meaningfully different, consolidate to a single section and rely on
	Flow to indicate repetition instead of duplicating content.

SECTION FORMATTING
- Section headers with colon and blank line after: "Intro:", "Verse 1:",
  "Chorus 1:", etc. Normalize common names; consistent numbering.

CHORDS-OVER-LYRICS RULES
- Convert inline chords to separate chord lines above lyrics. Keep chord names
  (slash, extensions, accidentals). Do not invent chords.

INSTRUMENTAL / BAR NOTATION
- For chord-only measures, use bars with pipes and sensible spacing. Keep
  repeated measures normalized.

ACTUAL GUITAR TAB (SOT/EOT)
- If six-string ASCII tab is present (e| B| G| D| A| E| etc.), wrap the tab in
  {sot}/{eot} inside the relevant section. Keep alignment; trim only true
  excess. Use string labels matching tuning if known; otherwise standard labels.
  Place any chord cue line above the tab; include legend lines if provided.

CLEANUP / NORMALIZATION
- Trim trailing spaces (except inside tab alignment). Collapse multiple blank
  lines to max one between blocks. Remove noise (credits/URLs) unless musically
  unique. Deduplicate identical sections (use Flow).
- If extra notes or instructions are present in the user input that are not
	part of the chart (e.g., recording notes, reminders), you may use them to
	infer structure/sections but DO NOT include them in formatted_tab.

METADATA LOOKUP + SAFETY
- Prefer confident lookups for Key/Capo/Tempo/Time; otherwise leave blank. If
  Capo unknown, set "Capo: 0". Default Tuning to Standard if not specified.
- TransposedKey only if confidently determinable; otherwise blank.

FINAL OUTPUT CHECK
- Must be valid JSON. formatted_tab must contain: Title, Artist, full metadata
  block (all fields, blanks allowed), blank line, then section blocks. No
  markdown, commentary, links, or citations.
PROMPT
)

	jq -n \
		--arg system "$system_prompt" \
		--arg raw "$input_text" \
		--arg model "$MODEL_NAME" \
		'{
			model: $model,
			temperature: 0.2,
			response_format: {type: "json_object"},
			messages: [
				{role: "system", content: $system},
				{role: "user", content: ("Format the following raw text into the target OnSong structure and respond only with the JSON object described above.\n\nRaw input:\n" + $raw)}
			]
		}'
}

parse_response() {
	local response_json="$1"

	response_json=$(RAW="$response_json" python - <<'PY'
import os, json
raw = os.environ.get("RAW", "")
raw = raw.replace("\r", "")
raw_escaped = raw.replace("\n", "\\n").replace("\t", "\\t")
data = json.loads(raw_escaped)
print(json.dumps(data))
PY
)

	local artist title tab
	artist=$(printf '%s' "$response_json" | jq -r '.artist // .Artist // empty')
	title=$(printf '%s' "$response_json" | jq -r '.song_title // .title // empty')
	tab=$(printf '%s' "$response_json" | jq -r '.formatted_tab // .formatted // .content // empty')

	[[ -z "$artist" ]] && artist="Unknown Artist"
	[[ -z "$title" ]] && title="Unknown Song"
	if [[ -z "$tab" ]]; then
		echo "Failed to parse OpenAI response (tab missing)" >&2
		return 1
	fi

	printf '%s\n%s\n%s' "$artist" "$title" "$tab"
}

rebuild_formatted_tab() {
	local tab_content="$1"
	local artist_fallback="$2"
	local title_fallback="$3"
	local file_base="$4"

	TAB_CONTENT="$tab_content" ARTIST_FB="$artist_fallback" TITLE_FB="$title_fallback" FILE_BASE="$file_base" python - <<'PY'
import os, re

CHORD_RE = re.compile(
	r"\b(?P<root>[A-G](?:#|b)?)(?P<qual>maj7|maj|min7|m7|m|min|dim|aug|sus2|sus4|add9|6|7|9|11|13|m6|m9|maj9)?(?:/[A-G](?:#|b)?)?\b"
)


def detect_key(body: str) -> str:
	root_counts: dict[str, int] = {}
	minor_counts: dict[str, int] = {}

	for match in CHORD_RE.finditer(body):
		root = match.group("root")
		qual = match.group("qual") or ""
		is_minor = qual.startswith("m") and not qual.startswith("maj")

		root_counts[root] = root_counts.get(root, 0) + 1
		if is_minor:
			minor_counts[root] = minor_counts.get(root, 0) + 1

	if not root_counts:
		return ""

	best_root = max(root_counts.items(), key=lambda item: item[1])[0]
	minor_hits = minor_counts.get(best_root, 0)
	total_hits = root_counts[best_root]

	if total_hits > 0 and minor_hits / total_hits >= 0.5:
		return f"{best_root}m"
	return best_root

tab = os.environ['TAB_CONTENT']
artist_fb = os.environ['ARTIST_FB']
title_fb = os.environ['TITLE_FB']
file_base = os.environ['FILE_BASE']

lines = tab.split('\n')

file_artist = ""
file_title = ""
if file_base:
	base_no_ext = file_base.rsplit('.', 1)[0]
	parts = base_no_ext.split(' - ', 1)
	if len(parts) == 2:
		file_artist, file_title = parts[0].strip(), parts[1].strip()
	else:
		file_title = base_no_ext.strip()

hdr_title = lines[0].strip() if len(lines) > 0 else ""
hdr_artist = lines[1].strip() if len(lines) > 1 else ""

meta_names = ['Key', 'Capo', 'Tempo', 'Time', 'Flow', 'Tuning', 'TransposedKey']
meta = {name: '' for name in meta_names}

for offset, name in enumerate(meta_names, start=2):
	if offset < len(lines):
		m = re.match(rf"^{name}:\s*(.*)$", lines[offset])
		if m:
			meta[name] = m.group(1).strip()

body_start = 2 + len(meta_names)
if body_start < len(lines) and lines[body_start].strip() == '':
	body_start += 1
body = '\n'.join(lines[body_start:]).lstrip('\n')

artist = hdr_artist or artist_fb or file_artist or "Unknown Artist"
title = hdr_title or title_fb or file_title or "Unknown Song"

if not meta['Capo']:
	meta['Capo'] = '0'
if not meta['Tuning']:
	meta['Tuning'] = 'Standard'

if not meta['Key']:
	meta['Key'] = detect_key(body)

if not meta['Flow']:
	section_tokens = []
	for line in body.split('\n'):
		if not line.strip():
			continue
		m = re.match(r'^([A-Za-z ]+):\s*$', line.strip())
		if not m:
			continue
		name = m.group(1).strip()
		low = name.lower()
		token = None
		if low.startswith('intro'):
			token = 'Intro'
		elif low.startswith('verse'):
			num = ''.join(ch for ch in name if ch.isdigit()) or '1'
			token = f'V{num}'
		elif 'pre' in low:
			num = ''.join(ch for ch in name if ch.isdigit()) or '1'
			token = f'PC{num}'
		elif 'chorus' in low:
			num = ''.join(ch for ch in name if ch.isdigit()) or '1'
			token = f'C{num}'
		elif 'bridge' in low or low == 'b':
			token = 'B'
		elif 'solo' in low:
			token = 'Solo'
		elif 'outro' in low:
			token = 'Outro'
		elif 'tag' in low:
			token = 'Tag'
		if token and token not in section_tokens:
			section_tokens.append(token)
	if section_tokens:
		meta['Flow'] = ' '.join(section_tokens)

header_lines = [
	title,
	artist,
	*(f"{name}: {meta[name]}" for name in meta_names),
	'',
	''
]

rebuilt = '\n'.join(header_lines) + body
print(rebuilt)
PY
}

main() {
	local input_file="" dry_run=0 debug_notes_flag=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--dry-run)
				dry_run=1
				shift
				;;
			--debug-notes)
				debug_notes_flag=1
				shift
				;;
			--help|-h)
				usage
				exit 0
				;;
			--*)
				echo "Unknown option: $1" >&2
				usage
				exit 1
				;;
			*)
				input_file="$1"
				shift
				;;
		esac
	done

	if [[ -z "$input_file" ]]; then
		usage
		exit 1
	fi

	if [[ ! -f "$input_file" ]]; then
		echo "Input file not found: $input_file" >&2
		exit 1
	fi

	require_command jq
	require_command curl

	export LOG_LEVEL=0
	export LOG_FD=2
	source "$SCRIPT_DIR/../utilities/logging.sh"
	setup_script_logging
	set_log_level "$LOG_LEVEL_NAME"
	log_header "organize-guitar-tabs.sh"

	if [[ ! -f "$SCRIPT_DIR/../ai/open-ai-functions.sh" ]]; then
		log_error "Missing OpenAI helper at $SCRIPT_DIR/../ai/open-ai-functions.sh"
		exit 1
	fi
	source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

	[[ $dry_run -eq 1 ]] || mkdir -p "$OUTPUT_DIR"

	local absolute_input
	absolute_input="$(cd "$(dirname "$input_file")" &>/dev/null && pwd)/$(basename "$input_file")"
	local raw_text
	raw_text=$(cat "$absolute_input")

	if [[ -z "$raw_text" ]]; then
		log_error "Input file is empty: $absolute_input"
		exit 1
	fi

	log_info "Sending content to OpenAI for formatting"
	local payload response_json parsed artist title tab filename target_path
	payload=$(build_request_body "$raw_text")
	response_json=$(get-openai-response "$payload")

	local debug_notes=""
	if [[ $debug_notes_flag -eq 1 ]]; then
		debug_notes=$(RAW="$response_json" python - <<'PY'
import os, json
raw = os.environ.get("RAW", "").replace("\r", "")
raw_escaped = raw.replace("\n", "\\n").replace("\t", "\\t")
data = json.loads(raw_escaped)
notes = data.get("debug_notes")
if isinstance(notes, str):
    notes_list = [notes]
elif isinstance(notes, list):
    notes_list = [str(n) for n in notes]
else:
    notes_list = []
print("\n".join(notes_list))
PY
)
	fi

	# Persist raw response for debugging
	print -r -- "$response_json" > "$HOME/Library/Logs/automation-scripts/organization/organize-guitar-tabs-last-response.txt"

	if ! parsed=$(parse_response "$response_json"); then
		log_error "Unable to parse OpenAI response"
		exit 1
	fi

	artist=$(printf '%s' "$parsed" | sed -n '1p')
	title=$(printf '%s' "$parsed" | sed -n '2p')
	tab=$(printf '%s' "$parsed" | sed -n '3,$p')
	tab="${tab//$'\\n'/$'\n'}"
	tab="${tab//$'\\t'/	}"

	# Rebuild header with fallbacks and derived flow
	tab=$(rebuild_formatted_tab "$tab" "$artist" "$title" "$(basename "$absolute_input")")

	artist=$(sanitize_component "$artist")
	title=$(sanitize_component "$title")

	filename="$artist - $title.txt"
	target_path="$OUTPUT_DIR/$filename"

	if [[ $dry_run -eq 1 ]]; then
		log_info "Dry-run: printing formatted tab"
		print -r -- "$tab"
		if [[ $debug_notes_flag -eq 1 && -n "$debug_notes" ]]; then
			while IFS= read -r line; do
				log_info "Debug change: $line"
			done <<< "$debug_notes"
		fi
	else
		print -r -- "$tab" > "$target_path"
		log_info "Wrote formatted tab to $target_path"
		if [[ $debug_notes_flag -eq 1 && -n "$debug_notes" ]]; then
			while IFS= read -r line; do
				log_info "Debug change: $line"
			done <<< "$debug_notes"
		fi
		# Remove the working copy so Hazel can clean up the original separately
		rm -f "$absolute_input"
	fi
}

main "$@"
