#!/usr/bin/env zsh

# shell safety
set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

TRAPPED_SIGNAL=""

if [[ "${TRACE-0}" == "1" ]]; then
	set -o xtrace
fi

PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"
SCRIPT_PATH="${(%):-%N}"
SCRIPT_DIR="${SCRIPT_PATH:A:h}"

DEFAULT_INTERVAL=10
INTERVAL="$DEFAULT_INTERVAL"
MAX_FRAMES=50
VIDEO_FILE=""
SUMMARIES_DIR=""
TEMP_BASE_DIR=""
WORK_DIR=""
FRAMES_DIR=""
FRAME_RESULTS_FILE=""
VISION_MODEL="${OPENAI_VISION_MODEL:-gpt-4o}"
SUMMARY_MODEL="${OPENAI_SUMMARY_MODEL:-gpt-4.1}"
AUDIO_MODEL="${OPENAI_AUDIO_MODEL:-whisper-1}"
AUDIO_FILE=""
AUDIO_TRANSCRIPT_PATH=""
FINAL_TRANSCRIPT_PATH=""
TRANSCRIPT_SNIPPET=""
HAS_AUDIO_TRACK=0
AUDIO_DIR=""
VIDEO_DURATION_SECONDS=""

require_command() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Missing required command: $cmd" >&2
		exit 1
	fi
}

usage() {
	cat <<'USAGE'
Usage: organize-video-imports.sh [options] <video_file>

Options:
	--interval <seconds>     Interval between frames (default: 10)
	--max-frames <count>     Cap the number of frames extracted (default: 50)
	--summaries-dir <path>   Directory to write the markdown summary (default: video directory)
	-h, --help               Show this help text
USAGE
}

parse_args() {
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--interval)
				[[ $# -lt 2 ]] && { echo "--interval requires a value" >&2; exit 1; }
				INTERVAL="$2"
				shift 2
				;;
			--max-frames)
				[[ $# -lt 2 ]] && { echo "--max-frames requires a value" >&2; exit 1; }
				MAX_FRAMES="$2"
				shift 2
				;;
			--summaries-dir)
				[[ $# -lt 2 ]] && { echo "--summaries-dir requires a value" >&2; exit 1; }
				SUMMARIES_DIR="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit 0
				;;
			--)
				shift
				break
				;;
			-*)
				echo "Unknown option: $1" >&2
				usage
				exit 1
				;;
			*)
				args+=("$1")
				shift
				;;
		esac
	done

	if (( ${#args[@]} == 0 )); then
		echo "A video file path is required" >&2
		usage
		exit 1
	fi

	VIDEO_FILE="${args[1]}"
}

cleanup() {
	:
}
trap cleanup EXIT

signal_handler() {
	local sig="$1"
	TRAPPED_SIGNAL="$sig"
	local ts
	ts=$(date -Iseconds 2>/dev/null || date)
	local msg
	msg="Received signal ${sig}; aborting run at ${ts}"
	local log_fn
	if typeset -f log_error >/dev/null 2>&1; then
		log_fn=log_error
	else
		log_fn=echo
	fi
	"$log_fn" "$msg" >&2
	local log_path
	log_path="${TEMP_BASE_DIR:-/tmp}/organize-video-imports.signal.log"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
	{
		printf '%s\n' "$msg"
		printf 'script_pid=%s ppid=%s tty=%s\n' "$$" "$PPID" "$(ps -o tty= -p "$$" 2>/dev/null | tr -d ' ')"
		printf 'parent_cmd=%s\n' "$(ps -o command= -p "$PPID" 2>/dev/null | sed 's/^ *//')"
		printf 'self_cmd=%s\n' "$(ps -o command= -p "$$" 2>/dev/null | sed 's/^ *//')"
		printf 'children=%s\n' "$(pgrep -P "$$" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
		printf 'user=%s\n' "${USER:-}"
		printf 'pwd=%s\n' "${PWD:-}"
		printf -- '---\n'
	} >>"$log_path" 2>/dev/null || true
	exit 130
}

trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP
trap 'signal_handler QUIT' QUIT

safe_remove_dir() {
	local target="$1"
	if [[ -z "$target" || ! -d "$target" ]]; then
		return 0
	fi
	if ! rm -Rf "$target" 2>/dev/null; then
		log_warn "Failed to remove $target (resource busy or permission issue); continuing"
	fi
}

format_timecode() {
	local seconds="$1"
	printf '%02d:%02d:%02d' $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}

detect_audio_track() {
	local audio_stream
	audio_stream=$(command ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$VIDEO_FILE" 2>/dev/null || true)
	if [[ -n "$audio_stream" ]]; then
		HAS_AUDIO_TRACK=1
		log_info "Audio track detected"
	else
		HAS_AUDIO_TRACK=0
		log_info "No audio track detected; skipping transcription"
	fi
}

get_video_duration_seconds() {
	if [[ -n "$VIDEO_DURATION_SECONDS" ]]; then
		return 0
	fi
	local duration
	duration=$(command ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null || true)
	VIDEO_DURATION_SECONDS=${duration%.*}
	if [[ -z "$VIDEO_DURATION_SECONDS" ]]; then
		VIDEO_DURATION_SECONDS=0
	fi
}

expected_frame_count() {
	get_video_duration_seconds
	local expected
	expected=$(( (VIDEO_DURATION_SECONDS / INTERVAL) + 1 ))
	if (( MAX_FRAMES > 0 && expected > MAX_FRAMES )); then
		expected=$MAX_FRAMES
	fi
	printf '%s' "$expected"
}

extract_audio_track() {
	if (( HAS_AUDIO_TRACK == 0 )); then
		return 0
	fi

	log_info "Extracting audio to $AUDIO_FILE"

	if [[ -s "$AUDIO_FILE" ]]; then
		log_info "Reusing existing extracted audio at $AUDIO_FILE"
		return 0
	fi

	log_info "Extracting audio to $AUDIO_FILE"

	if ! command ffmpeg -hide_banner -loglevel error -i "$VIDEO_FILE" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$AUDIO_FILE"; then
		log_warn "Failed to extract audio track; continuing without transcript"
		HAS_AUDIO_TRACK=0
		return 1
	fi

	if [[ ! -s "$AUDIO_FILE" ]]; then
		log_warn "Extracted audio file is empty; skipping transcription"
		HAS_AUDIO_TRACK=0
		return 1
	fi

	log_info "Audio extraction complete"
}

transcribe_audio_track() {
	if (( HAS_AUDIO_TRACK == 0 )); then
		return 0
	fi

	AUDIO_TRANSCRIPT_PATH="$AUDIO_DIR/audio_transcript.txt"
	FINAL_TRANSCRIPT_PATH="$SUMMARIES_DIR/$VIDEO_BASENAME.transcript.txt"
	mkdir -p "$SUMMARIES_DIR"

	local endpoint
	endpoint="${OPENAI_API_BASE_URL%/}/audio/transcriptions"

	log_info "Transcribing audio with model $AUDIO_MODEL"
	local tmp_response
	tmp_response=$(mktemp)

	local http_status
	if ! http_status=$(command curl -sS -o "$tmp_response" -w "%{http_code}" -X POST "$endpoint" \
		-H "Authorization: Bearer $API_KEY" \
		-F "file=@$AUDIO_FILE" \
		-F "model=$AUDIO_MODEL" \
		-F "response_format=text"); then
		log_warn "Audio transcription request failed"
		rm -f "$tmp_response"
		return 1
	fi

	local body
	body=$(cat "$tmp_response")
	rm -f "$tmp_response"

	if [[ "$http_status" != "200" ]]; then
		log_warn "Transcription failed (HTTP $http_status)"
		log_debug "Transcription response: ${body:0:500}"
		return 1
	fi

	printf '%s\n' "$body" >"$AUDIO_TRANSCRIPT_PATH"
	command cp "$AUDIO_TRANSCRIPT_PATH" "$FINAL_TRANSCRIPT_PATH" 2>/dev/null || true
	log_info "Transcript saved to $FINAL_TRANSCRIPT_PATH"

	prepare_transcript_snippet
}

prepare_transcript_snippet() {
	if [[ -z "$AUDIO_TRANSCRIPT_PATH" || ! -f "$AUDIO_TRANSCRIPT_PATH" ]]; then
		TRANSCRIPT_SNIPPET=""
		return
	fi

	local max_chars=4000
	local raw_snippet
	raw_snippet=$(command head -c "$max_chars" "$AUDIO_TRANSCRIPT_PATH" 2>/dev/null || true)
	TRANSCRIPT_SNIPPET=$(printf '%s' "$raw_snippet" | tr -d '\r')
}

describe_frame() {
	local frame_path="$1"
	local frame_index="$2"
	local timecode="$3"
	local time_seconds="$4"

	log_info "Describing frame $frame_index at $timecode"
	local start_ts
	start_ts=$(date +%s)

	# Heartbeat while waiting on the vision API
	local heartbeat_pid
	{
		while true; do
			sleep 30
			log_info "Still describing frame $frame_index (time $timecode)..."
		done
	} &
	heartbeat_pid=$!

	local b64_file
	b64_file="$WORK_DIR/frame_${frame_index}.b64"
	if ! base64 < "$frame_path" | tr -d '\n' >"$b64_file"; then
		log_warn "Failed to base64 encode $frame_path"
		return 0
	fi

	local payload
	payload=$(jq -n \
		--rawfile b64 "$b64_file" \
		--arg filename "$VIDEO_BASENAME" \
		--arg tc "$timecode" \
		--arg model "$VISION_MODEL" \
		'{
			model: $model,
			messages: [
				{
					role: "system",
					content: "You describe video frames concisely and objectively. Focus on subjects, actions, setting, and visible text. Avoid speculation."
				},
				{
					role: "user",
					content: [
						{"type": "text", "text": ("Video file name: " + $filename + "\nFrame time: " + $tc + "\nDescribe what is visible in 1-2 concise sentences." )},
						{"type": "image_url", "image_url": {"url": ("data:image/jpeg;base64," + ($b64 | gsub("[[:space:]]"; "")) ) }}
					]
				}
			],
			temperature: 0.2,
			max_completion_tokens: 200
		}')

	local desc
	if ! desc=$(get-openai-response "$payload"); then
		log_warn "AI description failed for frame $frame_index ($timecode)"
		if [[ -n "${heartbeat_pid:-}" ]]; then
			kill "$heartbeat_pid" 2>/dev/null || true
			wait "$heartbeat_pid" 2>/dev/null || true
		fi
		return 0
	fi

	if [[ -n "${heartbeat_pid:-}" ]]; then
		kill "$heartbeat_pid" 2>/dev/null || true
		wait "$heartbeat_pid" 2>/dev/null || true
	fi

	local end_ts
	end_ts=$(date +%s)
	local duration=$((end_ts - start_ts))

	log_info "Described frame $frame_index"
	log_info "Frame $frame_index duration: ${duration}s"

	jq -n --arg idx "$frame_index" --arg tc "$timecode" --arg desc "$desc" --arg ts "$time_seconds" \
		'{frame: ($idx|tonumber), timecode: $tc, description: $desc, timeSeconds: ($ts|tonumber)}'
}

summarize_video() {
	local scenes_json="$1"
	local transcript_snippet="${2:-}"

	local timeline
	timeline=$(printf '%s' "$scenes_json" | jq -r '.[] | "[\(.timecode)] \(.description)"' | paste -sd '\n' -)

	local transcript_section=""
	if [[ -n "$transcript_snippet" ]]; then
		transcript_section=$'\n\nAudio transcript excerpt (may be partial, clean as needed):\n'
		transcript_section+="$transcript_snippet"
	fi

	local payload_template
	payload_template=$(jq -n \
		--arg filename "$VIDEO_BASENAME" \
		--arg timeline "$timeline" \
		--arg transcript "$transcript_section" \
		--arg model "$SUMMARY_MODEL" \
		'{
			model: $model,
			messages: [
				{
					role: "system",
					content: "You are a concise video summarizer for home videos. Return ONLY strict JSON (no markdown, no code fences) that conforms to this JSON Schema: {\"type\": \"object\", \"required\": [\"title\", \"description\"], \"properties\": {\"title\": {\"type\": \"string\", \"minLength\": 1, \"maxLength\": 120}, \"description\": {\"type\": \"string\", \"minLength\": 40, \"maxLength\": 2000, \"description\": \"One paragraph, 3-10 sentences, personable and friendly home-video tone; no bullets, no lists, no timestamps, no markers. Describe what viewers will see.\"}}, \"additionalProperties\": false}. Include nothing else."
				},
				{
					role: "user",
					content: ("Video file: " + $filename + "\nTimeline entries (ordered):\n" + $timeline + $transcript + "\n\nReturn only JSON with fields title and description. No markdown, no labels, no code fences.")
				}
			],
			temperature: 0.25,
			max_completion_tokens: 500
		}')

	local attempt=0
	local response=""
	while (( attempt < 3 )); do
		attempt=$((attempt + 1))
		log_info "Summarizing video (attempt $attempt)"
		response=$(get-openai-response "$payload_template" || true)
		if [[ -n "$response" && "$response" != "null" ]]; then
			# strip whitespace to detect truly empty content
			local trimmed
			trimmed=$(printf '%s' "$response" | tr -d '\r\n[:space:]')
			if [[ -n "$trimmed" ]]; then
				log_info "Summary attempt $attempt succeeded"
				printf '%s' "$response"
				return 0
			fi
		fi
		log_warn "Empty summary response (attempt $attempt); retrying..."
		sleep 1
	done

	log_error "Failed to obtain non-empty summary after 3 attempts"
	return 1
}

extract_frames() {
	log_info "Extracting frames every ${INTERVAL}s${MAX_FRAMES:+ (cap: ${MAX_FRAMES} frame(s))}"
	mkdir -p "$FRAMES_DIR"

	local vframes_arg=()
	if (( MAX_FRAMES > 0 )); then
		vframes_arg=(-vframes "$MAX_FRAMES")
	fi

	local filter="fps=1/${INTERVAL},scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease"

	if ! ffmpeg -hide_banner -loglevel error -i "$VIDEO_FILE" -vf "$filter" -vsync vfr -q:v 8 "${vframes_arg[@]}" "$FRAMES_DIR/frame_%05d.jpg"; then
		log_error "ffmpeg frame extraction failed"
		exit 1
	fi

	local count=$(ls "$FRAMES_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$count" == "0" ]]; then
		log_error "No frames were extracted"
		exit 1
	fi

	log_info "Extracted $count frame(s)"
}

ensure_frames_ready() {
	local expected actual
	expected=$(expected_frame_count)
	if ls "$FRAMES_DIR"/frame_*.jpg >/dev/null 2>&1; then
		actual=$(ls "$FRAMES_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
		if (( expected > 0 && actual < expected )); then
			log_warn "Frames missing ($actual/$expected); re-extracting"
			safe_remove_dir "$FRAMES_DIR"
			mkdir -p "$FRAMES_DIR"
			extract_frames
		else
			log_info "Frames present: $actual/${expected:-unknown}; reusing"
		fi
	else
		extract_frames
	fi
}

process_frames() {
	[[ -f "$FRAME_RESULTS_FILE" ]] || : >"$FRAME_RESULTS_FILE"
	local idx=0
	local total_frames
	total_frames=$(ls "$FRAMES_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')

	for img in "$FRAMES_DIR"/frame_*.jpg; do
		idx=$((idx + 1))
		local ts_seconds=$(((idx - 1) * INTERVAL))
		local tc="$(format_timecode "$ts_seconds")"

		if command jq -e --argjson frame "$idx" 'select(.frame == $frame)' "$FRAME_RESULTS_FILE" >/dev/null 2>&1; then
			log_info "Reusing existing description for frame $idx"
			continue
		fi

		describe_frame "$img" "$idx" "$tc" "$ts_seconds" >>"$FRAME_RESULTS_FILE"

		if (( idx % 5 == 0 )); then
			log_info "Progress: described $idx/$total_frames frame(s)"
		fi
	done

	local described_count
	described_count=$(jq -s 'map(select(.description != null)) | length' "$FRAME_RESULTS_FILE" 2>/dev/null || echo 0)
	if (( described_count < total_frames )); then
		log_warn "Descriptions missing for some frames ($described_count/$total_frames); reprocessing missing frames"
		local tmp_file
		tmp_file=$(mktemp)
		command mv "$FRAME_RESULTS_FILE" "$tmp_file"
		: >"$FRAME_RESULTS_FILE"
		idx=0
		for img in "$FRAMES_DIR"/frame_*.jpg; do
			idx=$((idx + 1))
			if command jq -e --argjson frame "$idx" 'select(.frame == $frame and .description != null)' "$tmp_file" >/dev/null 2>&1; then
				command jq -c --argjson frame "$idx" 'select(.frame == $frame)' "$tmp_file" >>"$FRAME_RESULTS_FILE"
				continue
			fi
			local ts_seconds=$(((idx - 1) * INTERVAL))
			local tc="$(format_timecode "$ts_seconds")"
			describe_frame "$img" "$idx" "$tc" "$ts_seconds" >>"$FRAME_RESULTS_FILE"
		done
		rm -f "$tmp_file"
	fi
}

write_summary() {
	mkdir -p "$SUMMARIES_DIR"
	local summary_path="$SUMMARIES_DIR/$VIDEO_BASENAME.md"

	if [[ -s "$summary_path" ]]; then
		log_info "Summary already exists at $summary_path; skipping rewrite"
		SUMMARY_PATH="$summary_path"
		return 0
	fi

	local scenes_json
	scenes_json=$(jq -s 'map(select(.description != null)) | sort_by(.timeSeconds // 0)' "$FRAME_RESULTS_FILE")

	if [[ "$(printf '%s' "$scenes_json" | jq 'length')" == "0" ]]; then
		log_warn "No frame descriptions available for summary; reprocessing frames"
		process_frames
		scenes_json=$(jq -s 'map(select(.description != null)) | sort_by(.timeSeconds // 0)' "$FRAME_RESULTS_FILE")
		if [[ "$(printf '%s' "$scenes_json" | jq 'length')" == "0" ]]; then
			log_error "No frame descriptions available for summary after retry"
			exit 1
		fi
	fi

	local summary
	summary=$(summarize_video "$scenes_json" "$TRANSCRIPT_SNIPPET")

	local summary_json
	if ! summary_json=$(printf '%s' "$summary" | jq '.' 2>/dev/null); then
		log_error "Summary response was not valid JSON"
		exit 1
	fi

	local title description
	title=$(printf '%s' "$summary_json" | jq -r '.title // empty')
	description=$(printf '%s' "$summary_json" | jq -r '.description // empty')

	if [[ -z "$title" || -z "$description" ]]; then
		log_error "Summary JSON missing title or description"
		exit 1
	fi

    local formatted
    formatted=$(printf '# %s\n\n%s\n\n%s\n' "$title" "AI-generated video summary; check for accuracy." "$description" | perl -0pe '
    s/\r\n?/\n/g;
    s/[ \t]+/ /g;
    s/^# */# /;
    s/\n{3,}/\n\n/g;
    s/\n +/\n/g;
    END { $_ .= "\n" unless /\n\z/; }
')

	printf '%s' "$formatted" >"$summary_path"
	log_info "Wrote summary to $summary_path"
	SUMMARY_PATH="$summary_path"
	if command -v open >/dev/null 2>&1; then
		open -R "$summary_path" || true
	fi
}

main() {
	parse_args "$@"

	require_command ffmpeg
	require_command ffprobe
	require_command jq
	require_command base64
	require_command stat
	require_command curl

	VIDEO_FILE="$(cd "$(dirname "$VIDEO_FILE")" &>/dev/null && pwd)/$(basename "$VIDEO_FILE")"
	[[ -f "$VIDEO_FILE" ]] || { echo "Video file not found: $VIDEO_FILE" >&2; exit 1; }

	VIDEO_DIR="$(cd "$(dirname "$VIDEO_FILE")" &>/dev/null && pwd)"
	VIDEO_BASENAME="${VIDEO_FILE##*/}"
	VIDEO_BASENAME="${VIDEO_BASENAME%.*}"
	VIDEO_EXT="${VIDEO_FILE##*.}"
	MOVED_VIDEO_PATH="$VIDEO_FILE"

	if [[ -z "$SUMMARIES_DIR" ]]; then
		SUMMARIES_DIR="$VIDEO_DIR"
	fi

	export LOG_LEVEL=0
	export LOG_FD=2
	if [[ ! -f "$SCRIPT_DIR/../utilities/logging.sh" ]]; then
		ALT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
		if [[ -f "$ALT_DIR/../utilities/logging.sh" ]]; then
			SCRIPT_DIR="$ALT_DIR"
		fi
	fi
	source "$SCRIPT_DIR/../utilities/logging.sh"
	setup_script_logging
	set_log_level "INFO"
	log_header "organize-video-imports.sh"

	source "$SCRIPT_DIR/../ai/open-ai-functions.sh"

	TEMP_BASE_DIR="$VIDEO_DIR/_temp"
	WORK_DIR="$TEMP_BASE_DIR/$VIDEO_BASENAME"
	FRAME_RESULTS_FILE="$WORK_DIR/scenes.jsonl"
	FRAMES_DIR="$WORK_DIR/frames"
	AUDIO_DIR="$WORK_DIR/audio"
	AUDIO_TRANSCRIPT_PATH="$WORK_DIR/audio_transcript.txt"
	FINAL_TRANSCRIPT_PATH="$SUMMARIES_DIR/$VIDEO_BASENAME.transcript.txt"

	mkdir -p "$TEMP_BASE_DIR" "$WORK_DIR" "$FRAMES_DIR" "$AUDIO_DIR"

	log_info "Processing video: $(basename "$VIDEO_FILE")"
	log_info "Interval: ${INTERVAL}s | Summaries dir: $SUMMARIES_DIR"
	AUDIO_FILE="$AUDIO_DIR/audio.wav"

	detect_audio_track
	ensure_frames_ready
	process_frames

	if [[ -f "$AUDIO_TRANSCRIPT_PATH" ]]; then
		log_info "Reusing cached audio transcript from $AUDIO_TRANSCRIPT_PATH"
		prepare_transcript_snippet
	elif (( HAS_AUDIO_TRACK )); then
		extract_audio_track || true
		transcribe_audio_track || log_warn "Audio transcription failed; continuing with visual summary only"
	fi
	write_summary

	log_divider "DONE"
	log_info "Summary: ${SUMMARY_PATH:-n/a}"
	log_info "Processed video: ${MOVED_VIDEO_PATH:-n/a}"
}

main "$@"
