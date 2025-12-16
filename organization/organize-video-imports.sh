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

DEFAULT_INTERVAL=15
CONCURRENCY=${AI_CONCURRENCY:-4}
KEEP_TEMP=0
INTERVAL="$DEFAULT_INTERVAL"
VIDEO_FILE=""
SUMMARIES_DIR=""
TEMP_BASE_DIR=""
WORK_DIR=""
FRAMES_DIR=""
FRAME_RESULTS_FILE=""
VISION_MODEL="${OPENAI_VISION_MODEL:-gpt-4o}"
SUMMARY_MODEL="${OPENAI_SUMMARY_MODEL:-gpt-5.1}"

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
	--interval <seconds>     Interval between frames (default: 15)
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
			--summaries-dir)
				[[ $# -lt 2 ]] && { echo "--summaries-dir requires a value" >&2; exit 1; }
				SUMMARIES_DIR="$2"
				shift 2
				;;
			--keep-temp)
				KEEP_TEMP=1
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
		return 0
	fi

	jq -n --arg idx "$frame_index" --arg tc "$timecode" --arg desc "$desc" --arg ts "$time_seconds" \
		'{frame: ($idx|tonumber), timecode: $tc, description: $desc, timeSeconds: ($ts|tonumber)}'
}

summarize_video() {
	local scenes_json="$1"

	local timeline
	timeline=$(printf '%s' "$scenes_json" | jq -r '.[] | "[\(.timecode)] \(.description)"' | paste -sd '\n' -)

	local payload
	payload=$(jq -n \
		--arg filename "$VIDEO_BASENAME" \
		--arg timeline "$timeline" \
		--arg model "$SUMMARY_MODEL" \
		'{
			model: $model,
			messages: [
				{
					role: "system",
					content: "You are a precise video summarizer. Respond ONLY with valid, neatly spaced Markdown. Use this exact structure with blank lines between sections:\n# <Video Title>\n## Summary\n- 2-3 sentences (1 bullet per sentence)\n## Highlights\n- 3-6 bullets of key subjects/actions/locations\n## Timeline\n- One bullet per timeline entry, preserve order and timestamps.\nEnd with a trailing newline."
				},
				{
					role: "user",
					content: ("Video file: " + $filename + "\nTimeline entries (ordered):\n" + $timeline + "\n\nFollow the specified Markdown format exactly. Do not inline everything. Each bullet on its own line. Include a final newline.")
				}
			],
			temperature: 0.25,
			max_completion_tokens: 700
		}')

	get-openai-response "$payload"
}

extract_frames() {
	log_info "Extracting frames every ${INTERVAL}s"
	FRAMES_DIR="$WORK_DIR/frames"
	mkdir -p "$FRAMES_DIR"

	if ! ffmpeg -hide_banner -loglevel error -i "$VIDEO_FILE" -vf "fps=1/${INTERVAL}" -q:v 2 "$FRAMES_DIR/frame_%05d.jpg"; then
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
	FRAME_RESULTS_FILE=$(mktemp -t video-scenes.XXXXXX.jsonl)
	local idx=0

	for img in "$FRAMES_DIR"/frame_*.jpg; do
		idx=$((idx + 1))
		local ts_seconds=$(((idx - 1) * INTERVAL))
		local tc="$(format_timecode "$ts_seconds")"

		while (( $(jobs -p | wc -l) >= CONCURRENCY )); do
			sleep 0.1
		done

		describe_frame "$img" "$idx" "$tc" "$ts_seconds" >>"$FRAME_RESULTS_FILE" &
	done

	wait
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

	# Normalize markdown spacing in case the model returns a single line
	local formatted
	formatted=$(printf '%s' "$summary" | perl -0pe '
s/\r\n?/\n/g;
s/[ \t]+/ /g;
s/ *## */\n\n## /g;
s/^# */# /;
s/\n{3,}/\n\n/g;
s/ *- /\n- /g;
s/\n +/\n/g;
END { $_ .= "\n" unless /\n\z/; }
')

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

	mkdir -p "$TEMP_BASE_DIR"
	rm -rf "$WORK_DIR"
	mkdir -p "$WORK_DIR"

	log_info "Processing video: $(basename "$VIDEO_FILE")"
	log_info "Interval: ${INTERVAL}s | Summaries dir: $SUMMARIES_DIR"

	extract_frames
	process_frames
	write_summary

	if (( KEEP_TEMP )); then
		log_info "Temp directory kept at $WORK_DIR"
	fi

	log_divider "DONE"
	log_info "Summary: ${SUMMARY_PATH:-n/a}"
	log_info "Processed video: ${MOVED_VIDEO_PATH:-n/a}"
}

main "$@"
