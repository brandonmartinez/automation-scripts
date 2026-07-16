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
command mkdir -p "$failure_source"
print -r -- "failure" >"$failure_source/model.stl"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'exit 7'
} >"$failure_organizer"
command chmod +x "$failure_organizer"
command zsh "$WRAPPER" "$failure_source" >/dev/null

if ORGANIZE_3D_ORGANIZER="$failure_organizer" command zsh "$WORKER" >/dev/null; then
    fail "worker returns failure when organizer fails"
else
    pass "worker returns failure when organizer fails"
fi
assert_count "failed job is retained" 1 "$THREE_D_FAILED_DIR"
if command jq -e '.history[-1].message == "Organizer exited with status 7"' \
    "$THREE_D_FAILED_DIR"/*/job.json >/dev/null; then
    pass "failed manifest records organizer exit code"
else
    fail "failed manifest records organizer exit code"
fi

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
