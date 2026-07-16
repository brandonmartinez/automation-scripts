#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail

readonly TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
readonly JOB_FUNCTIONS="$REPO_ROOT/hazel/3d-import-job-functions.sh"
readonly WRAPPER="$REPO_ROOT/hazel/hazel-organize-3d-imports-wrapper.sh"
readonly WORKER="$REPO_ROOT/hazel/hazel-organize-3d-imports-worker.sh"
typeset -i PASSED=0
typeset -i FAILED=0

pass() {
    print -r -- "PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    print -u2 -r -- "FAIL: $1"
    FAILED=$((FAILED + 1))
}

assert_count() {
    local description="$1"
    local expected="$2"
    local directory="$3"
    local -a entries
    entries=("$directory"/*(N/))
    if (( ${#entries[@]} == expected )); then
        pass "$description"
    else
        fail "$description (expected $expected, got ${#entries[@]})"
    fi
}

tmp_dir=$(command mktemp -d)
cleanup_test_directory() {
    if [[ "${KEEP_TEST_TEMP:-0}" == "1" ]]; then
        print -u2 -r -- "Preserved test directory: $tmp_dir"
    else
        command rm -rf "$tmp_dir"
    fi
}
trap cleanup_test_directory EXIT
export ORGANIZE_3D_BASE_PATH="$tmp_dir/archive"
export ORGANIZE_3D_SPOOL_ROOT="$tmp_dir/spool"
export ORGANIZE_3D_STAGING_ROOT="$tmp_dir/staging"
export ORGANIZE_3D_LEGACY_QUEUE="$tmp_dir/legacy-queue"
export ORGANIZE_3D_WORKER_LOG="$tmp_dir/worker.log"
export ORGANIZE_3D_NO_WORKER=1
export ORGANIZE_3D_DISABLE_NOTIFICATIONS=1

command mkdir -p "$tmp_dir/one/Same Name" "$tmp_dir/two/Same Name"
print -r -- "first" >"$tmp_dir/one/Same Name/model.stl"
print -r -- "second" >"$tmp_dir/two/Same Name/model.stl"

first_output=$(command zsh "$WRAPPER" "$tmp_dir/one/Same Name")
second_output=$(command zsh "$WRAPPER" "$tmp_dir/two/Same Name")
first_id="${${first_output#*job }%% *}"
second_id="${${second_output#*job }%% *}"

if [[ "$first_id" != "$second_id" ]]; then
    pass "same-named imports receive unique job IDs"
else
    fail "same-named imports receive unique job IDs"
fi

source "$JOB_FUNCTIONS"
assert_count "both jobs are atomically pending" 2 "$THREE_D_PENDING_DIR"

publication_collision_id="publication-collision"
print -r -- "occupied" >"$THREE_D_PENDING_DIR/$publication_collision_id"
if publish_3d_job "$publication_collision_id" "Collision" "$tmp_dir/collision-payload" 2>/dev/null; then
    fail "failed publication is not reported as accepted"
else
    pass "failed publication is not reported as accepted"
fi
if [[ "$(<"$THREE_D_PENDING_DIR/$publication_collision_id")" == "occupied" ]] &&
    [[ ! -e "$THREE_D_PENDING_DIR/.${publication_collision_id}.tmp.$$" ]]; then
    pass "failed publication cleans its temporary manifest"
else
    fail "failed publication cleans its temporary manifest"
fi
command rm -f "$THREE_D_PENDING_DIR/$publication_collision_id"

status_before="$tmp_dir/status-before.json"
fake_bin="$tmp_dir/fake-bin"
command cp "$THREE_D_STATUS_FILE" "$status_before"
command mkdir "$fake_bin"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'exit 55'
} >"$fake_bin/jq"
command chmod +x "$fake_bin/jq"
if PATH="$fake_bin:$PATH" command zsh -c 'source "$1"; write_3d_spool_status "must fail"' _ "$JOB_FUNCTIONS"; then
    fail "failed status generation returns failure"
else
    pass "failed status generation returns failure"
fi
typeset -a status_temps
status_temps=("$THREE_D_STATUS_FILE".tmp.*(N))
if command cmp -s "$status_before" "$THREE_D_STATUS_FILE" &&
    (( ${#status_temps[@]} == 0 )); then
    pass "failed status generation preserves the last valid status"
else
    fail "failed status generation preserves the last valid status"
fi

first_payload=$(command jq -r '.stagingPath' "$THREE_D_PENDING_DIR/$first_id/job.json")
second_payload=$(command jq -r '.stagingPath' "$THREE_D_PENDING_DIR/$second_id/job.json")
if [[ "$(<"$first_payload/model.stl")" == "first" && "$(<"$second_payload/model.stl")" == "second" ]]; then
    pass "same-named payloads remain isolated"
else
    fail "same-named payloads remain isolated"
fi

fake_organizer="$tmp_dir/fake-organizer.sh"
command cp /dev/null "$fake_organizer"
command chmod +x "$fake_organizer"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'set -o errexit -o nounset -o pipefail'
    print -r -- 'command rm -rf "$1"'
} >"$fake_organizer"

export ORGANIZE_3D_ORGANIZER="$fake_organizer"
export ORGANIZE_3D_WORKER_ONCE=1
command zsh "$WORKER" >/dev/null

assert_count "worker drains pending jobs" 0 "$THREE_D_PENDING_DIR"
assert_count "worker leaves no running jobs" 0 "$THREE_D_RUNNING_DIR"
assert_count "worker records completed jobs" 2 "$THREE_D_DONE_DIR"
assert_count "completed staging containers are removed" 0 "$THREE_D_STAGING_ROOT"

legacy_path="$tmp_dir/legacy/Legacy Import"
command mkdir -p "$legacy_path"
print -r -- "legacy" >"$legacy_path/legacy.3mf"
print -r -- "$legacy_path" >"$ORGANIZE_3D_LEGACY_QUEUE"
command zsh "$WORKER" >/dev/null

assert_count "legacy queue entry migrates into spool" 3 "$THREE_D_DONE_DIR"
if [[ ! -s "$ORGANIZE_3D_LEGACY_QUEUE" ]]; then
    pass "legacy queue is empty after migration"
else
    fail "legacy queue is empty after migration"
fi

if command jq -se 'all(.[]; all(.history[]; (.state == "pending" or .state == "running" or .state == "done")))' \
    "$THREE_D_DONE_DIR"/*/job.json >/dev/null; then
    pass "job manifests preserve lifecycle history"
else
    fail "job manifests preserve lifecycle history"
fi

failure_source="$tmp_dir/failure/Failure Import"
failure_organizer="$tmp_dir/failing-organizer.sh"
failure_notifications="$tmp_dir/failure/notifications.log"
failure_notifier="$tmp_dir/failure/notifier.sh"
command mkdir -p "$failure_source"
print -r -- "failure" >"$failure_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'exit 7'
} >"$failure_organizer"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'print -r -- "$1|$2" >>"$ORGANIZE_3D_NOTIFICATION_LOG"'
} >"$failure_notifier"
command chmod +x "$failure_organizer" "$failure_notifier"
ORGANIZE_3D_MAX_ATTEMPTS=1 command zsh "$WRAPPER" "$failure_source" >/dev/null

if ORGANIZE_3D_ORGANIZER="$failure_organizer" \
    ORGANIZE_3D_NOTIFY_COMMAND="$failure_notifier" \
    ORGANIZE_3D_NOTIFICATION_LOG="$failure_notifications" \
    ORGANIZE_3D_DISABLE_NOTIFICATIONS=0 \
    command zsh "$WORKER" >/dev/null; then
    fail "worker returns failure when organizer fails"
else
    pass "worker returns failure when organizer fails"
fi
assert_count "failed job is quarantined" 1 "$THREE_D_QUARANTINE_DIR"
if command jq -e '
    .state == "quarantined" and
    .lastExitCode == 7 and
    any(.history[]; .message == "Organizer exited with status 7")
' "$THREE_D_QUARANTINE_DIR"/*/job.json >/dev/null; then
    pass "failed manifest records organizer exit code"
else
    fail "failed manifest records organizer exit code"
fi
if command grep -Fq "3D Import Needs Attention|Failure Import was quarantined after 1 failed attempts." \
    "$failure_notifications"; then
    pass "quarantined import sends attention notification"
else
    fail "quarantined import sends attention notification"
fi

retry_root="$tmp_dir/retry"
retry_source="$retry_root/source/Retry Import"
retry_counter="$retry_root/attempts"
retry_organizer="$retry_root/flaky-organizer.sh"
retry_notifications="$retry_root/notifications.log"
retry_notifier="$retry_root/notifier.sh"
command mkdir -p "$retry_source"
print -r -- "retry" >"$retry_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'attempt=0'
    print -r -- '[[ -f "$ORGANIZE_3D_RETRY_COUNTER" ]] && attempt=$(<"$ORGANIZE_3D_RETRY_COUNTER")'
    print -r -- 'attempt=$((attempt + 1))'
    print -r -- 'print -r -- "$attempt" >"$ORGANIZE_3D_RETRY_COUNTER"'
    print -r -- '(( attempt == 1 )) && exit 9'
    print -r -- 'command rm -rf "$1"'
} >"$retry_organizer"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'print -r -- "$1|$2" >>"$ORGANIZE_3D_NOTIFICATION_LOG"'
} >"$retry_notifier"
command chmod +x "$retry_organizer" "$retry_notifier"

ORGANIZE_3D_BASE_PATH="$retry_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$retry_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$retry_root/staging" \
    ORGANIZE_3D_MAX_ATTEMPTS=3 \
    ORGANIZE_3D_NO_WORKER=1 \
    command zsh "$WRAPPER" "$retry_source" >/dev/null

ORGANIZE_3D_BASE_PATH="$retry_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$retry_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$retry_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$retry_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$retry_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$retry_organizer" \
    ORGANIZE_3D_RETRY_COUNTER="$retry_counter" \
    ORGANIZE_3D_RETRY_BASE_SECONDS=1 \
    ORGANIZE_3D_RETRY_MAX_SECONDS=1 \
    ORGANIZE_3D_WORKER_ONCE=1 \
    command zsh "$WORKER" >/dev/null

assert_count "transient failure returns to pending" 1 "$retry_root/spool/pending"
if command jq -e '
    .state == "pending" and
    .attempts == 1 and
    any(.history[]; .state == "failed") and
    any(.history[]; .message == "Retry scheduled in 1s")
' "$retry_root/spool/pending"/*/job.json >/dev/null; then
    pass "retry manifest records failed attempt and backoff"
else
    fail "retry manifest records failed attempt and backoff"
fi

command sleep 1.1
ORGANIZE_3D_BASE_PATH="$retry_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$retry_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$retry_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$retry_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$retry_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$retry_organizer" \
    ORGANIZE_3D_RETRY_COUNTER="$retry_counter" \
    ORGANIZE_3D_RETRY_BASE_SECONDS=1 \
    ORGANIZE_3D_RETRY_MAX_SECONDS=1 \
    ORGANIZE_3D_NOTIFY_COMMAND="$retry_notifier" \
    ORGANIZE_3D_NOTIFICATION_LOG="$retry_notifications" \
    ORGANIZE_3D_DISABLE_NOTIFICATIONS=0 \
    ORGANIZE_3D_WORKER_ONCE=1 \
    command zsh "$WORKER" >/dev/null

assert_count "retry succeeds on second attempt" 1 "$retry_root/spool/done"
if command jq -e '.state == "done" and .attempts == 2 and .lastExitCode == 0' \
    "$retry_root/spool/done"/*/job.json >/dev/null; then
    pass "completed retry records final lifecycle"
else
    fail "completed retry records final lifecycle"
fi
if command grep -Fq "3D Import Complete|Retry Import was organized successfully." "$retry_notifications"; then
    pass "successful import sends final notification"
else
    fail "successful import sends final notification"
fi
if command jq -e '
    .counts.pending == 0 and
    .counts.running == 0 and
    .counts.quarantined == 0 and
    .counts.done == 1
' "$retry_root/spool/status.json" >/dev/null; then
    pass "spool status summarizes lifecycle counts"
else
    fail "spool status summarizes lifecycle counts"
fi

recovery_root="$tmp_dir/recovery-test"
recovery_source="$recovery_root/source/Recovered Import"
command mkdir -p "$recovery_source"
print -r -- "recovery" >"$recovery_source/model.stl"
recovery_output=$(
    ORGANIZE_3D_BASE_PATH="$recovery_root/archive" \
        ORGANIZE_3D_SPOOL_ROOT="$recovery_root/spool" \
        ORGANIZE_3D_STAGING_ROOT="$recovery_root/staging" \
        ORGANIZE_3D_MAX_ATTEMPTS=3 \
        ORGANIZE_3D_NO_WORKER=1 \
        command zsh "$WRAPPER" "$recovery_source"
)
recovery_job_id="${${recovery_output#*job }%% *}"
command mv "$recovery_root/spool/pending/$recovery_job_id" "$recovery_root/spool/running/$recovery_job_id"
command jq '
    .state = "running" |
    .attempts = 1 |
    .activeWorkerPid = 999999 |
    .history += [{state: "running", at: .updatedAt, message: "Interrupted worker"}]
' "$recovery_root/spool/running/$recovery_job_id/job.json" \
    >"$recovery_root/spool/running/$recovery_job_id/job.json.tmp"
command mv "$recovery_root/spool/running/$recovery_job_id/job.json.tmp" \
    "$recovery_root/spool/running/$recovery_job_id/job.json"

ORGANIZE_3D_BASE_PATH="$recovery_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$recovery_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$recovery_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$recovery_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$recovery_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$fake_organizer" \
    ORGANIZE_3D_RETRY_BASE_SECONDS=0 \
    ORGANIZE_3D_RETRY_MAX_SECONDS=0 \
    ORGANIZE_3D_WORKER_ONCE=1 \
    command zsh "$WORKER" >/dev/null

assert_count "abandoned running job is recovered" 1 "$recovery_root/spool/done"
if command jq -e '
    .attempts == 2 and
    any(.history[]; .message == "Recovered abandoned running job")
' "$recovery_root/spool/done/$recovery_job_id/job.json" >/dev/null; then
    pass "recovered job records crash history"
else
    fail "recovered job records crash history"
fi

completed_recovery_root="$tmp_dir/completed-recovery"
completed_recovery_source="$completed_recovery_root/source/Completed Recovery"
command mkdir -p "$completed_recovery_source"
print -r -- "completed recovery" >"$completed_recovery_source/model.stl"
completed_recovery_output=$(
    ORGANIZE_3D_BASE_PATH="$completed_recovery_root/archive" \
        ORGANIZE_3D_SPOOL_ROOT="$completed_recovery_root/spool" \
        ORGANIZE_3D_STAGING_ROOT="$completed_recovery_root/staging" \
        ORGANIZE_3D_NO_WORKER=1 \
        command zsh "$WRAPPER" "$completed_recovery_source"
)
completed_recovery_job_id="${${completed_recovery_output#*job }%% *}"
command mv "$completed_recovery_root/spool/pending/$completed_recovery_job_id" \
    "$completed_recovery_root/spool/running/$completed_recovery_job_id"
command jq '
    .state = "done" |
    .attempts = 1 |
    .lastExitCode = 0 |
    .history += [{state: "done", at: .updatedAt, message: "Organizer completed before crash"}]
' "$completed_recovery_root/spool/running/$completed_recovery_job_id/job.json" \
    >"$completed_recovery_root/spool/running/$completed_recovery_job_id/job.json.tmp"
command mv "$completed_recovery_root/spool/running/$completed_recovery_job_id/job.json.tmp" \
    "$completed_recovery_root/spool/running/$completed_recovery_job_id/job.json"

ORGANIZE_3D_BASE_PATH="$completed_recovery_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$completed_recovery_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$completed_recovery_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$completed_recovery_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$completed_recovery_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$fake_organizer" \
    ORGANIZE_3D_WORKER_ONCE=1 \
    ORGANIZE_3D_DISABLE_NOTIFICATIONS=1 \
    command zsh "$WORKER" >/dev/null

assert_count "completed crash-window job remains completed" 1 "$completed_recovery_root/spool/done"
if command jq -e '
    .state == "done" and
    .lastExitCode == 0 and
    any(.history[]; .message == "Organizer completed before crash") and
    all(.history[]; .message != "Recovered abandoned running job")
' "$completed_recovery_root/spool/done/$completed_recovery_job_id/job.json" >/dev/null; then
    pass "completed recovery preserves committed lifecycle state"
else
    fail "completed recovery preserves committed lifecycle state"
fi
assert_count "completed recovery cleans staging container" 0 "$completed_recovery_root/staging"

failed_recovery_root="$tmp_dir/failed-recovery"
failed_recovery_source="$failed_recovery_root/source/Failed Recovery"
command mkdir -p "$failed_recovery_source"
print -r -- "failed recovery" >"$failed_recovery_source/model.stl"
failed_recovery_output=$(
    ORGANIZE_3D_BASE_PATH="$failed_recovery_root/archive" \
        ORGANIZE_3D_SPOOL_ROOT="$failed_recovery_root/spool" \
        ORGANIZE_3D_STAGING_ROOT="$failed_recovery_root/staging" \
        ORGANIZE_3D_NO_WORKER=1 \
        command zsh "$WRAPPER" "$failed_recovery_source"
)
failed_recovery_job_id="${${failed_recovery_output#*job }%% *}"
command mv "$failed_recovery_root/spool/pending/$failed_recovery_job_id" \
    "$failed_recovery_root/spool/running/$failed_recovery_job_id"
command jq '
    .state = "failed" |
    .attempts = 0 |
    .lastExitCode = 42 |
    .lastError = "Original organizer failure" |
    .history += [{state: "failed", at: .updatedAt, message: "Organizer exited with status 42"}]
' "$failed_recovery_root/spool/running/$failed_recovery_job_id/job.json" \
    >"$failed_recovery_root/spool/running/$failed_recovery_job_id/job.json.tmp"
command mv "$failed_recovery_root/spool/running/$failed_recovery_job_id/job.json.tmp" \
    "$failed_recovery_root/spool/running/$failed_recovery_job_id/job.json"

ORGANIZE_3D_BASE_PATH="$failed_recovery_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$failed_recovery_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$failed_recovery_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$failed_recovery_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$failed_recovery_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$fake_organizer" \
    ORGANIZE_3D_RETRY_BASE_SECONDS=0 \
    ORGANIZE_3D_RETRY_MAX_SECONDS=0 \
    ORGANIZE_3D_WORKER_ONCE=1 \
    ORGANIZE_3D_DISABLE_NOTIFICATIONS=1 \
    command zsh "$WORKER" >/dev/null

assert_count "failed crash-window job retries successfully" 1 "$failed_recovery_root/spool/done"
if command jq -e '
    .attempts == 2 and
    any(.history[]; .message == "Organizer exited with status 42") and
    all(.history[]; .message != "Recovered abandoned running job")
' "$failed_recovery_root/spool/done/$failed_recovery_job_id/job.json" >/dev/null; then
    pass "failed recovery preserves exit details and counts prior attempt"
else
    fail "failed recovery preserves exit details and counts prior attempt"
fi

automatic_root="$tmp_dir/automatic-retry"
automatic_source="$automatic_root/source/Automatic Retry"
automatic_counter="$automatic_root/attempts"
automatic_organizer="$automatic_root/flaky-organizer.sh"
command mkdir -p "$automatic_source"
print -r -- "automatic retry" >"$automatic_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'attempt=0'
    print -r -- '[[ -f "$ORGANIZE_3D_RETRY_COUNTER" ]] && attempt=$(<"$ORGANIZE_3D_RETRY_COUNTER")'
    print -r -- 'attempt=$((attempt + 1))'
    print -r -- 'print -r -- "$attempt" >"$ORGANIZE_3D_RETRY_COUNTER"'
    print -r -- '(( attempt == 1 )) && exit 9'
    print -r -- 'command rm -rf "$1"'
} >"$automatic_organizer"
command chmod +x "$automatic_organizer"

ORGANIZE_3D_BASE_PATH="$automatic_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$automatic_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$automatic_root/staging" \
    ORGANIZE_3D_MAX_ATTEMPTS=3 \
    ORGANIZE_3D_NO_WORKER=1 \
    command zsh "$WRAPPER" "$automatic_source" >/dev/null

ORGANIZE_3D_BASE_PATH="$automatic_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$automatic_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$automatic_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$automatic_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$automatic_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$automatic_organizer" \
    ORGANIZE_3D_RETRY_COUNTER="$automatic_counter" \
    ORGANIZE_3D_RETRY_BASE_SECONDS=1 \
    ORGANIZE_3D_RETRY_MAX_SECONDS=1 \
    ORGANIZE_3D_DISABLE_NOTIFICATIONS=1 \
    ORGANIZE_3D_WORKER_ONCE=0 \
    command zsh "$WORKER" >/dev/null

wait_attempt=0
typeset -a automatic_done_jobs
while ((wait_attempt < 40)); do
    automatic_done_jobs=("$automatic_root/spool/done"/*(N/))
    (( ${#automatic_done_jobs[@]} > 0 )) && break
    command sleep 0.1
    wait_attempt=$((wait_attempt + 1))
done
assert_count "deferred retry wakes a future worker automatically" 1 "$automatic_root/spool/done"

detached_root="$tmp_dir/detached"
detached_source="$detached_root/source/Detached Import"
detached_marker="$detached_root/worker-finished"
detached_worker="$detached_root/fake-worker.sh"
command mkdir -p "$detached_source"
print -r -- "detached" >"$detached_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'command sleep 1'
    print -r -- 'print -r -- done >"$ORGANIZE_3D_DETACHED_MARKER"'
} >"$detached_worker"
command chmod +x "$detached_worker"

ORGANIZE_3D_BASE_PATH="$detached_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$detached_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$detached_root/staging" \
    ORGANIZE_3D_WORKER_LOG="$detached_root/worker.log" \
    ORGANIZE_3D_WORKER="$detached_worker" \
    ORGANIZE_3D_DETACHED_MARKER="$detached_marker" \
    ORGANIZE_3D_NO_WORKER=0 \
    command zsh "$WRAPPER" "$detached_source" >/dev/null

if [[ ! -e "$detached_marker" ]]; then
    pass "wrapper returns before detached worker completes"
else
    fail "wrapper returns before detached worker completes"
fi

typeset -i wait_attempt=0
while [[ ! -e "$detached_marker" ]] && ((wait_attempt < 30)); do
    command sleep 0.1
    wait_attempt=$((wait_attempt + 1))
done
if [[ -e "$detached_marker" ]]; then
    pass "detached worker remains alive after wrapper exits"
else
    fail "detached worker remains alive after wrapper exits"
fi

lock_root="$tmp_dir/lock-test"
lock_source="$lock_root/source/Lock Import"
lock_marker="$lock_root/organizer-started"
lock_release="$lock_root/release-organizer"
lock_organizer="$lock_root/blocking-organizer.sh"
command mkdir -p "$lock_source"
print -r -- "lock" >"$lock_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'print -r -- "$$" >"$ORGANIZE_3D_LOCK_MARKER"'
    print -r -- 'while [[ ! -e "$ORGANIZE_3D_LOCK_RELEASE" ]]; do command sleep 0.05; done'
    print -r -- 'command rm -rf "$1"'
} >"$lock_organizer"
command chmod +x "$lock_organizer"

ORGANIZE_3D_BASE_PATH="$lock_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$lock_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$lock_root/staging" \
    ORGANIZE_3D_NO_WORKER=1 \
    command zsh "$WRAPPER" "$lock_source" >/dev/null

ORGANIZE_3D_BASE_PATH="$lock_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$lock_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$lock_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$lock_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$lock_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$lock_organizer" \
    ORGANIZE_3D_LOCK_MARKER="$lock_marker" \
    ORGANIZE_3D_LOCK_RELEASE="$lock_release" \
    ORGANIZE_3D_WORKER_ONCE=1 \
    command zsh "$WORKER" >/dev/null &
first_worker_pid=$!

wait_attempt=0
while [[ ! -e "$lock_marker" ]] && ((wait_attempt < 30)); do
    command sleep 0.1
    wait_attempt=$((wait_attempt + 1))
done

ORGANIZE_3D_BASE_PATH="$lock_root/archive" \
    ORGANIZE_3D_SPOOL_ROOT="$lock_root/spool" \
    ORGANIZE_3D_STAGING_ROOT="$lock_root/staging" \
    ORGANIZE_3D_LEGACY_QUEUE="$lock_root/legacy-queue" \
    ORGANIZE_3D_WORKER_LOG="$lock_root/worker.log" \
    ORGANIZE_3D_ORGANIZER="$lock_organizer" \
    ORGANIZE_3D_WORKER_ONCE=1 \
    command zsh "$WORKER" >/dev/null

if [[ "$(<"$lock_root/spool/.worker-lock")" == "$first_worker_pid" ]]; then
    pass "concurrent worker cannot steal active lock"
else
    fail "concurrent worker cannot steal active lock"
fi

print -r -- "release" >"$lock_release"
wait "$first_worker_pid"
if [[ ! -e "$lock_root/spool/.worker-lock" ]]; then
    pass "worker removes only its owned lock"
else
    fail "worker removes only its owned lock"
fi

print -r -- ""
print -r -- "Passed: $PASSED"
print -r -- "Failed: $FAILED"
((FAILED == 0))
