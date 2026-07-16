#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail

readonly TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
readonly ORGANIZER="$REPO_ROOT/organization/organize-3d-imports.sh"
readonly AI_HELPERS="$REPO_ROOT/ai/open-ai-functions.sh"
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

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_false() {
    local description="$1"
    shift
    if "$@"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_jq() {
    local description="$1"
    local expression="$2"
    local file="$3"
    if command jq -e "$expression" "$file" >/dev/null; then
        pass "$description"
    else
        fail "$description"
    fi
}

test_agent_plan_boundary() {
    local tmp_dir
    tmp_dir=$(command mktemp -d)

    ORGANIZE_3D_LIBRARY_ONLY=1 source "$ORGANIZER"
    INPUT_PATH="$tmp_dir/input"
    command mkdir -p "$INPUT_PATH"
    WORK_STATE_FILE="$tmp_dir/state.json"
    command jq -n '{
        metadata: {totalFiles: 1, agentCycles: []},
        files: [{
            id: 0,
            relativePath: "MakerWorld/iPad 240mm NFC QR.stl",
            filename: "iPad 240mm NFC QR.stl",
            proposed: {folder: null, filename: null, path: null, rationale: null}
        }]
    }' >"$WORK_STATE_FILE"

    local valid_plan
    valid_plan='{"files":[{"id":0,"proposed":{"folder":"files/STLs","filename":"iPad 240mm NFC QR.stl","path":"files/STLs/iPad 240mm NFC QR.stl","rationale":"Model"}}]}'
    assert_true "valid suggestion-only plan accepted" validate_agent_plan "$valid_plan"
    merge_agent_plan "$valid_plan"
    assert_jq "local inventory survives merge" '.files[0].relativePath == "MakerWorld/iPad 240mm NFC QR.stl"' "$WORK_STATE_FILE"
    assert_jq "suggestion merged by file ID" '.files[0].proposed.path == "files/STLs/iPad 240mm NFC QR.stl"' "$WORK_STATE_FILE"

    local mutated_plan absolute_plan traversal_plan
    mutated_plan='{"files":[{"id":0,"relativePath":"/tmp/replaced.stl","proposed":{"folder":null,"filename":null,"path":null,"rationale":null}}]}'
    absolute_plan='{"files":[{"id":0,"proposed":{"folder":null,"filename":"x.stl","path":"/tmp/x.stl","rationale":null}}]}'
    traversal_plan='{"files":[{"id":0,"proposed":{"folder":"../escape","filename":"x.stl","path":"../escape/x.stl","rationale":null}}]}'
    assert_false "AI cannot replace immutable inventory fields" validate_agent_plan "$mutated_plan"
    assert_false "absolute AI path rejected" validate_agent_plan "$absolute_plan"
    assert_false "parent traversal rejected" validate_agent_plan "$traversal_plan"

    local outside
    outside="$tmp_dir/outside"
    command mkdir -p "$outside"
    command ln -s "$outside" "$INPUT_PATH/link"
    assert_false "symlinked parent cannot escape staging root" is_safe_relative_path "link/escaped.stl"
    command rm -rf "$tmp_dir"
}

test_external_recovery_and_relative_state() {
    local tmp_dir input archive recovery destination state recovery_zip
    tmp_dir=$(command mktemp -d)
    input="$tmp_dir/drop/Fixture Import"
    archive="$tmp_dir/archive"
    recovery="$tmp_dir/recovery"
    command mkdir -p "$input/nested"
    print -r -- "solid fixture" >"$input/nested/model.stl"
    print -r -- "generated" >"$input/SUMMARY.md"
    print -r -- '{}' >"$input/agentic-plan.json"
    print -r -- "old backup" >"$input/Fixture Import_backup_20200101.zip"

    ORGANIZE_3D_BASE_PATH="$archive" \
        ORGANIZE_3D_RECOVERY_DIR="$recovery" \
        ORGANIZE_3D_NO_REVEAL=1 \
        command zsh "$ORGANIZER" --skip-ai "$input" >/dev/null 2>&1

    destination="$archive/Unsorted/Needs Review/Fixture Import"
    state="$destination/agentic-plan.json"
    recovery_zip=$(command find "$recovery" -name source.zip -type f -print -quit)

    assert_true "skip-AI import archived successfully" test -d "$destination"
    assert_true "recovery archive created outside project" test -f "$recovery_zip"
    assert_false "recovery archive is not inside archived project" test -f "$destination/source.zip"
    assert_jq "schema v2 state persisted" '.metadata.schemaVersion == "2.0"' "$state"
    assert_jq "state records relative file paths" 'all(.files[]; (.relativePath | startswith("/") | not))' "$state"
    assert_jq "generated artifacts excluded from inventory" 'all(.files[]; (.filename != "SUMMARY.md" and .filename != "agentic-plan.json" and (.filename | endswith("_backup_20200101.zip") | not)))' "$state"

    local zip_listing
    zip_listing=$(command unzip -Z1 "$recovery_zip")
    if [[ "$zip_listing" == *"SUMMARY.md"* || "$zip_listing" == *"agentic-plan.json"* || "$zip_listing" == *"_backup_20200101.zip"* ]]; then
        fail "generated artifacts excluded from recovery archive"
    else
        pass "generated artifacts excluded from recovery archive"
    fi

    if command jq -e '.. | strings | select(startswith("/"))' "$state" >/dev/null; then
        fail "persisted state contains no absolute filesystem paths"
    else
        pass "persisted state contains no absolute filesystem paths"
    fi
    command rm -rf "$tmp_dir"
}

test_model_capabilities() {
    log_info() { :; }
    LOGGING_INITIALIZED=1
    AI_PROVIDER=copilot
    source "$AI_HELPERS"
    assert_true "modern OpenAI model keeps json_schema output" model-supports-json-schema "gpt-5.4"
    assert_true "gpt-4o keeps json_schema output" model-supports-json-schema "gpt-4o"
    assert_false "legacy gpt-4 model uses json_object fallback" model-supports-json-schema "gpt-4-turbo"
}

test_agent_plan_boundary
test_external_recovery_and_relative_state
test_model_capabilities

print -r -- ""
print -r -- "Passed: $PASSED"
print -r -- "Failed: $FAILED"
((FAILED == 0))
