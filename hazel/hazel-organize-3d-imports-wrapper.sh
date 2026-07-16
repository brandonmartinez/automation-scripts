#!/usr/bin/env zsh
set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/3d-import-job-functions.sh"

if [[ $# -ne 1 || ! -d "$1" ]]; then
    print -u2 -r -- "Usage: $0 <directory>"
    exit 1
fi

src="$1"
worker="${ORGANIZE_3D_WORKER:-$script_dir/hazel-organize-3d-imports-worker.sh}"
worker_log="${ORGANIZE_3D_WORKER_LOG:-$HOME/Library/Logs/automation-scripts/hazel/hazel-organize-3d-imports-worker.log}"

job_id=$(enqueue_3d_import "$src")
print -r -- "Accepted 3D import job $job_id for $(basename "$src")"

if [[ "${ORGANIZE_3D_NO_WORKER:-0}" != "1" ]]; then
    command mkdir -p "$(dirname "$worker_log")"
    nohup "$worker" </dev/null >>"$worker_log" 2>&1 &!
fi

exit 0
