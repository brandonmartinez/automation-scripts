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
Usage: organize-guitar-tabs.sh [--debug] <text-file>

Formats a raw lyrics/chords text file into OnSong-style tab output using OpenAI
and writes the result to $GUITAR_TAB_OUTPUT (or a default folder) with the name
"ARTIST - SONG.txt".

Options:
	--debug   Write formatted tab next to original with a -debug suffix (keeps original)
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
- JSON must include exactly these keys: "artist", "song_title", "formatted_tab".
- Do NOT include any other keys (no debug or notes fields).
- "artist": normalized artist name (string).
- "song_title": normalized song title (string).
- "formatted_tab": the FULL OnSong text exactly as it should be written to the
	.tab file (string). All newlines MUST be escaped as literal "\\n" inside the
	JSON string (no raw newlines inside JSON strings). Emit compact, single-line
JSON.

HARD REQUIREMENTS
- Plain text only inside formatted_tab. ASCII only (straight quotes, normal
  hyphens).
- Preserve song content; normalize formatting and spacing.
- Chords must be ABOVE lyrics (chords-over-lyrics). Do NOT leave inline chords.
- Instrumental chord runs use bar notation with pipes: "| G   Em7   | Cadd9  G D |".
- Produce a reduced chart: include each unique section once; use Flow for
  repetition.

TITLE + ARTIST NORMALIZATION
- Normalize title/artist using standard conventions based solely on provided
	text. If not confident, keep best normalized input.
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
- If more than one distinct section of the same type exists (e.g., multiple
	verses, pre-choruses, choruses), number ALL of them sequentially (Verse 1,
	Verse 2, PC1, PC2, C1, C2, etc.) and ensure Flow uses the numbered tokens.
- If later sections of the same type are lyrically/chordally identical to an
	earlier one, do not duplicate the content; keep a single canonical section
	and reference it multiple times in Flow (e.g., one Chorus 1 with multiple C1
	entries in Flow).
- If a later chorus starts with the entirety of Chorus 1 and then adds new
	lines, keep Chorus 1 as the canonical full chorus and create Chorus 2 with
	ONLY the additional lines. Flow should indicate "C1, C2" to represent the
	base chorus followed by its tagged extension.
- If a section repeats identical content within the same block (e.g., a chorus
	written twice in one section), collapse it to a single canonical section and
	represent the repeats in Flow by repeating its token (e.g., "C1 C1").
- Check for repeated sections (esp. choruses/pre-choruses). If a later version
	is not meaningfully different, consolidate to a single section and rely on
	Flow to indicate repetition instead of duplicating content.

SECTION FORMATTING
- Section headers with colon and blank line after: "Intro:", "Verse 1:",
  "Chorus 1:", etc. Normalize common names; consistent numbering.

MIXED SECTIONS (CHORD + LYRIC)
- If a section contains chord measures followed by lyrics (e.g., Intro with a
	bar line then sung words), keep BOTH the chord block and the lyric lines in
	that section. Do NOT collapse it to an instrumental-only bar line.

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
- If chord diagram blocks (e.g., "Chord  D   x x 0 2 3 2") appear at the
	start, use them only to verify chord spellings; do NOT include them in
	formatted_tab.
- If extra notes or instructions (legends, comment blocks, how-to-play notes)
	appear at the end or inline and are not part of the chart, you may use them
	to infer structure/sections but DO NOT include them in formatted_tab.

METADATA FILL + SAFETY
- Derive Key/Capo/Tempo/Time only from provided text; otherwise leave blank.
	If Capo unknown, set "Capo: 0". Default Tuning to Standard if not specified.
- TransposedKey only if determinable from provided text; otherwise blank.

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

build_validator_body() {
	local formatted_tab="$1"

	local system_prompt

	system_prompt=$(cat <<'VPROMPT'
You are a strict validator and minimal fixer for formatted OnSong charts. Input
is an already-formatted chart string. Verify the chart follows all rules below
and return JSON only.

OUTPUT FORMAT (JSON ONLY)
- Return ONLY a single JSON object with keys: "formatted_tab" (string),
  "issues" (array of strings), "fixed" (boolean).
- If no issues, return the input chart unchanged and set fixed to false.

RULES TO ENFORCE
- Header lines present: Title, Artist, then metadata block (Key, Capo, Tempo,
  Time, Flow, Tuning, TransposedKey), blank line, then sections.
- Tuning must be present (default Standard acceptable). Capo present (0 if
  unknown). Flow present.
- Section headers colon-suffixed with numbering where needed.
- Flow uses compact tokens (Intro, V1, V2, PC1, C1, C2, B, Solo, Outro, Tag).
- If multiple distinct sections of a type exist, number all (Verse 1/2, PC1/2,
  C1/2, etc.).
- If later sections are identical to earlier ones, do not duplicate content;
  Flow should repeat the token instead.
- If a chorus starts with the entirety of Chorus 1 and then adds new lines,
  keep Chorus 1 canonical and make Chorus 2 contain only the additional lines;
  Flow should show C1 then C2.
- If a section repeats identical content within its own block, collapse to one
  block and repeat its token in Flow (e.g., C1 C1).
- Chords-over-lyrics only; no inline chords. Bar lines for instrumentals.
- Mixed chord+lyric sections must retain both the bar/chord lines AND the lyric
	lines beneath; do not convert to instrumental-only.
- If unlabeled hook/vocal lines immediately follow any section (or its bars),
	keep them within that section instead of creating a new section; only start
	a new section when a clear heading/title is present.

FIX STRATEGY
- If violations are found, minimally repair the chart to comply with rules and
  return the corrected chart in formatted_tab with fixed=true. Preserve song
  content; do not invent chords/lyrics.

FAIL-SAFE
- If you cannot confidently fix, return the original chart, fixed=false, and
  include issues describing blockers.
VPROMPT
)

	jq -n \
		--arg system "$system_prompt" \
		--arg formatted "$formatted_tab" \
		--arg model "$MODEL_NAME" \
		'{
			model: $model,
			temperature: 0.2,
			response_format: {type: "json_object"},
			messages: [
				{role: "system", content: $system},
				{role: "user", content: ("Validate and minimally fix the following formatted chart. Respond only with JSON as specified.\n\nChart:\n" + $formatted)}
			]
		}'
}

parse_response() {
	local response_json="$1"

	local raw sanitized artist title tab compact_raw reparsed
	raw="${response_json//$'\r'/}"
	sanitized="$raw"

	# If JSON parse fails due to unescaped newlines, try reparsing by slurping as raw text
	# If sanitized is a JSON string, decode it; otherwise try raw parse, then fallback to slurped parse
	if reparsed=$(printf '%s' "$sanitized" | jq -e 'if type=="string" then fromjson else . end' 2>/dev/null); then
		sanitized="$reparsed"
	fi

	if ! printf '%s' "$sanitized" | jq -e . >/dev/null 2>&1; then
		reparsed=$(printf '%s' "$sanitized" | jq -R -s 'fromjson?') || true
		if [[ -n "$reparsed" && "$reparsed" != "null" ]]; then
			sanitized="$reparsed"
		fi
	fi

	# If still not parseable, try decoding in case the entire payload is a quoted JSON string
	if ! printf '%s' "$sanitized" | jq -e . >/dev/null 2>&1; then
		reparsed=$(printf '%s' "$raw" | jq -R -s 'fromjson?') || true
		if [[ -n "$reparsed" && "$reparsed" != "null" ]]; then
			sanitized="$reparsed"
		fi
	fi

	if printf '%s' "$sanitized" | jq -e . >/dev/null 2>&1; then
		artist=$(printf '%s' "$sanitized" | jq -r 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | .artist // .Artist // empty')
		title=$(printf '%s' "$sanitized" | jq -r 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | .song_title // .title // empty')
		tab=$(printf '%s' "$sanitized" | jq -r 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | .formatted_tab // .formatted // .content // empty')
	else
		print -ru2 -- "Failed to parse JSON response; attempting fallback extraction"
		fallback=$(printf '%s' "$raw" | jq -R -s '
			def grab(re): (capture(re) // empty);
			{
			  artist:      (grab("(?s).*\"artist\"\\s*:\\s*\"(?<v>[^\"]*)\".*").v // ""),
			  song_title:  (grab("(?s).*\"song_title\"\\s*:\\s*\"(?<v>[^\"]*)\".*").v // ""),
			  formatted_tab: (grab("(?s).*\"formatted_tab\"\\s*:\\s*\"(?<v>.*)\"\\s*\\}?\\s*$").v // "")
			}
		')
		artist=$(printf '%s' "$fallback" | jq -r '.artist // empty')
		title=$(printf '%s' "$fallback" | jq -r '.song_title // empty')
		tab=$(printf '%s' "$fallback" | jq -r '.formatted_tab // empty')
	fi

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

	TAB_CONTENT="$tab_content" \
		ARTIST_FB="$artist_fallback" \
		TITLE_FB="$title_fallback" \
		FILE_BASE="$file_base" \
		python "$SCRIPT_DIR/organize-guitar-tabs-format.py"
}

main() {
	local input_file="" debug_mode=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--debug)
				debug_mode=1
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

	if [[ $debug_mode -eq 0 ]]; then
		mkdir -p "$OUTPUT_DIR"
	fi

	local absolute_input input_dir
	absolute_input="$(cd "$(dirname "$input_file")" &>/dev/null && pwd)/$(basename "$input_file")"
	input_dir="$(dirname "$absolute_input")"
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

	log_info "Running validation pass"
	local validator_payload validator_response validator_fixed validator_tab validator_issues
	validator_payload=$(build_validator_body "$tab")
	validator_response=$(get-openai-response "$validator_payload")

	validator_tab=$(
		set -o pipefail
		raw=$(printf '%s' "$validator_response" | tr -d '\r')
		# Decode validator response even if it returns a JSON string with literal newlines
		decoded=$(printf '%s' "$raw" | jq -R -s 'fromjson? // .')
		if jq -e . >/dev/null 2>&1 <<<"$decoded"; then
			tab=$(jq -r 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | .formatted_tab // .chart // .tab // ""' <<<"$decoded")
			issues_json=$(jq -c 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | .issues // []' <<<"$decoded")
			fixed_val=$(jq -r 'if type=="string" then (gsub("\n"; "\\n") | fromjson? // {}) else . end | if has("fixed") then (.fixed|tostring) else "false" end' <<<"$decoded")
		else
			tab=$(printf '%s' "$raw" | LC_ALL=C sed -n 's/.*"formatted_tab"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -n1)
			issues_json='[]'
			fixed_val='false'
		fi
		printf '{"tab":%s,"issues":%s,"fixed":%s}\n' \
			"$(printf '%s' "$tab" | jq -Rs .)" \
			"$issues_json" \
			"$(printf '%s' "$fixed_val" | jq -r 'if .=="true" or .=="1" then "true" else "false" end')"
	)

		validator_fixed=$(printf '%s' "$validator_tab" | jq -r '.fixed')
		validator_issues=$(printf '%s' "$validator_tab" | jq -r '.issues[]?' || true)
		local candidate_tab
		candidate_tab=$(printf '%s' "$validator_tab" | jq -r '.tab')
		if [[ -n "$candidate_tab" ]]; then
			tab="$candidate_tab"
			if [[ "$validator_fixed" == "true" ]]; then
				log_info "Validator applied fixes"
			fi
		else
			log_warn "Validator returned empty tab; keeping original"
		fi
		if [[ -n "$validator_issues" ]]; then
			while IFS= read -r line; do
				log_info "Validation issue: $line"
			done <<< "$validator_issues"
		fi

	artist=$(sanitize_component "$artist")
	title=$(sanitize_component "$title")

	local filename_base filename target_path debug_target
	filename_base="$artist - $title"
	filename="$filename_base.txt"
	target_path="$OUTPUT_DIR/$filename"
	debug_target="$input_dir/${filename_base}-debug.txt"

	if [[ $debug_mode -eq 1 ]]; then
		print -r -- "$tab" > "$debug_target"
		log_info "Debug mode: wrote formatted tab to $debug_target (original preserved)"
		log_info "Debug mode: original left in place at $absolute_input"
	else
		print -r -- "$tab" > "$target_path"
		log_info "Wrote formatted tab to $target_path"
		# Remove the working copy so Hazel can clean up the original separately
		rm -f "$absolute_input"
	fi
}

main "$@"
