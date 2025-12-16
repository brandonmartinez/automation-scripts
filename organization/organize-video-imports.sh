#!/usr/bin/env zsh

# shell safety
set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

if [[ "${TRACE-0}" == "1" ]]; then
	set -o xtrace
fi

SCRIPT_PATH="${(%):-%N}"
SCRIPT_DIR="${SCRIPT_PATH:A:h}"

DEFAULT_INTERVAL=12
KEEP_TEMP=0
REUSE_DESCRIPTIONS=0
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
	--interval <seconds>     Interval between frames (default: 12)
	--max-frames <count>     Cap the number of frames extracted (default: 50)
	--summaries-dir <path>   Directory to write the markdown summary
	--keep-temp              Keep temporary working directory (for debugging)
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
			--keep-temp)
				KEEP_TEMP=1
				shift
				;;
			--reuse-descriptions)
				REUSE_DESCRIPTIONS=1
				shift
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
	if (( KEEP_TEMP == 0 )) && [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
}
trap cleanup EXIT

format_timecode() {
	local seconds="$1"
	printf '%02d:%02d:%02d' $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
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

	local b64
	if ! b64=$(base64 < "$frame_path" | tr -d '\n'); then
		log_warn "Failed to base64 encode $frame_path"
		return 0
	fi

	local payload
	payload=$(jq -n \
		--arg b64 "$b64" \
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
						{"type": "image_url", "image_url": {"url": ("data:image/jpeg;base64," + $b64) }}
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

	local timeline
	timeline=$(printf '%s' "$scenes_json" | jq -r '.[] | "[\(.timecode)] \(.description)"' | paste -sd '\n' -)

	local payload_template
	payload_template=$(jq -n \
		--arg filename "$VIDEO_BASENAME" \
		--arg timeline "$timeline" \
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
					content: ("Video file: " + $filename + "\nTimeline entries (ordered):\n" + $timeline + "\n\nReturn only JSON with fields title and description. No markdown, no labels, no code fences.")
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
	FRAMES_DIR="$WORK_DIR/frames"
	mkdir -p "$FRAMES_DIR"

	local vframes_arg=()
	if (( MAX_FRAMES > 0 )); then
		vframes_arg=(-vframes "$MAX_FRAMES")
	fi

	local filter="fps=1/${INTERVAL}"

	if ! ffmpeg -hide_banner -loglevel error -i "$VIDEO_FILE" -vf "$filter" -vsync vfr -q:v 2 "${vframes_arg[@]}" "$FRAMES_DIR/frame_%05d.jpg"; then
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

process_frames() {
	FRAME_RESULTS_FILE="$WORK_DIR/scenes.jsonl"
	: >"$FRAME_RESULTS_FILE"
	local idx=0
	local total_frames
	total_frames=$(ls "$FRAMES_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')

	for img in "$FRAMES_DIR"/frame_*.jpg; do
		idx=$((idx + 1))
		local ts_seconds=$(((idx - 1) * INTERVAL))
		local tc="$(format_timecode "$ts_seconds")"

		describe_frame "$img" "$idx" "$tc" "$ts_seconds" >>"$FRAME_RESULTS_FILE"

		if (( idx % 5 == 0 )); then
			log_info "Progress: described $idx/$total_frames frame(s)"
		fi
	done
}

write_summary() {
	mkdir -p "$SUMMARIES_DIR"
	local summary_path="$SUMMARIES_DIR/$VIDEO_BASENAME.md"

	local scenes_json
	scenes_json=$(jq -s 'map(select(.description != null)) | sort_by(.timeSeconds // 0)' "$FRAME_RESULTS_FILE")

	if [[ "$(printf '%s' "$scenes_json" | jq 'length')" == "0" ]]; then
		log_error "No frame descriptions available for summary"
		exit 1
	fi

	local summary
	summary=$(summarize_video "$scenes_json")

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
	formatted=$(printf '# %s\n\n%s\n' "$title" "$description" | perl -0pe '
	s/\r\n?/\n/g;
	s/[ \t]+/ /g;
	s/^# */# /;
	s/\n{3,}/\n\n/g;
	s/\n +/\n/g;
	END { $_ .= "\n" unless /\n\z/; }
')

	printf '\nAI-generated summary of video file: %s.%s\n' "$VIDEO_BASENAME" "$VIDEO_EXT" >>"$summary_path"
	printf '%s' "$formatted" >"$summary_path"
	log_info "Wrote summary to $summary_path"
	SUMMARY_PATH="$summary_path"
}

main() {
	parse_args "$@"

	require_command ffmpeg
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

	mkdir -p "$TEMP_BASE_DIR"
	if ! (( REUSE_DESCRIPTIONS )) || [[ ! -f "$FRAME_RESULTS_FILE" ]]; then
		rm -rf "$WORK_DIR"
		mkdir -p "$WORK_DIR"
	fi

	log_info "Processing video: $(basename "$VIDEO_FILE")"
	log_info "Interval: ${INTERVAL}s | Summaries dir: $SUMMARIES_DIR"

	if (( REUSE_DESCRIPTIONS )) && [[ -f "$FRAME_RESULTS_FILE" ]]; then
		log_info "Reusing cached frame descriptions from $FRAME_RESULTS_FILE"
	else
		if (( REUSE_DESCRIPTIONS )); then
			log_warn "Requested reuse but no cache found at $FRAME_RESULTS_FILE; running extraction"
		fi
		extract_frames
		process_frames
	fi
	write_summary

	if (( KEEP_TEMP )); then
		log_info "Temp directory kept at $WORK_DIR"
	fi

	log_divider "DONE"
	log_info "Summary: ${SUMMARY_PATH:-n/a}"
	log_info "Processed video: ${MOVED_VIDEO_PATH:-n/a}"
}

main "$@"
