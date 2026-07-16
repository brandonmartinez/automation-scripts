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

assert_equal() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '$actual')"
    fi
}

test_agent_plan_boundary() {
    local tmp_dir
    tmp_dir=$(command mktemp -d)

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
    print -r -- "solid fixture" >"$input/nested/copy.stl"
    print -r -- "cad fixture" >"$input/nested/bracket.SLDPRT"
    print -r -- "print export" >"$input/nested/plate.bgcode"
    print -r -- "vector preview" >"$input/nested/preview.svg"
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
    assert_jq "inventory records SHA-256 for every file" 'all(.files[]; (.sha256 | test("^[0-9a-f]{64}$")))' "$state"
    assert_jq "within-import duplicate uses deterministic first path" '
        any(.metadata.duplicates[];
            .type == "content" and
            .relativePath == "nested/model.stl" and
            .duplicateOf == "nested/copy.stl" and
            (.sha256 | test("^[0-9a-f]{64}$"))
        )
    ' "$state"
    assert_jq "expanded formats receive deterministic categories" '
        (.files[] | select(.filename == "bracket.SLDPRT") | .category) == "3d-model" and
        (.files[] | select(.filename == "plate.bgcode") | .category) == "print-export" and
        (.files[] | select(.filename == "preview.svg") | .category) == "image"
    ' "$state"

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

test_deterministic_normalization_and_taxonomy() {
    local structure
    structure='{
        "categories": [
            {
                "name": "Arts and Crafts",
                "subcategories": [{"name": "Cardboard Tools"}]
            },
            {
                "name": "Personal Accessories",
                "subcategories": [{"name": "Keyrings & Keychains"}]
            },
            {
                "name": "Toys Games And Characters",
                "subcategories": []
            },
            {
                "name": "Toys, Games, and Characters",
                "subcategories": []
            }
        ]
    }'

    assert_equal "filename normalization preserves brands, acronyms, and units" \
        "iPad NFC Mount 240mm.stl" \
        "$(normalize_filename "ipad_NFC_mount_240MM.STL")"
    assert_equal "mixed-case brands and technical tokens retain casing" \
        "MakerWorld USB-C Holder M3x10mm.stl" \
        "$(normalize_filename "MakerWorld_USB-C_holder_M3x10mm.STL")"
    assert_equal "known slicer and material names normalize canonically" \
        "Bambu Lab X1-C PETG 500g.3mf" \
        "$(normalize_filename "bambulab_x1-c_PETG_500g.3MF")"
    assert_equal "decimal dimensions retain their numeric meaning" \
        "Spacer 2.5mm M3x0.5mm.stl" \
        "$(normalize_filename "spacer_2.5mm_M3x0.5mm.STL")"
    assert_equal "spaced metric thread tokens are rejoined before title casing" \
        "Desk Cable Clip M3x0.5mm.stl" \
        "$(normalize_filename "desk cable clip M3 x 0.5 mm.STL")"
    assert_equal "spaced gram units are rejoined before title casing" \
        "Filament 500g Spool.stl" \
        "$(normalize_filename "filament 500 g spool.STL")"
    assert_equal "ordinary in phrases are not treated as measurements" \
        "Model 3 In One.stl" \
        "$(normalize_filename "model 3 in one.STL")"
    assert_equal "numeric-to-word boundaries are restored" \
        "Phase 6 Adjustable Monitor Riser.stl" \
        "$(normalize_filename "phase 6adjustable monitor riser.STL")"
    assert_equal "recognized numeric technical tokens remain joined" \
        "3D Printer 32V 2.5mm.stl" \
        "$(normalize_filename "3d printer 32V 2.5mm.STL")"
    assert_equal "unlisted uppercase technical acronyms are preserved" \
        "24V PSU PCB Mount.stl" \
        "$(normalize_filename "24V_PSU_PCB_mount.STL")"
    assert_equal "hyphenated material acronyms retain casing" \
        "PETG-CF Bracket.stl" \
        "$(normalize_filename "PETG-CF_bracket.STL")"

    assert_equal "SOLIDWORKS files use a canonical folder" \
        "files/SOLIDWORKS" \
        "$(canonical_folder_for_extension "SLDPRT")"
    assert_equal "binary G-code files use exports" \
        "exports" \
        "$(canonical_folder_for_extension "bgcode")"
    assert_equal "mesh interchange files use a canonical folder" \
        "files/Meshes" \
        "$(canonical_folder_for_extension "GLB")"

    assert_equal "category punctuation aliases resolve to the preferred taxonomy" \
        "Toys, Games, and Characters" \
        "$(canonicalize_archive_category "Toys Games And Characters" "$structure")"
    assert_equal "ampersand category aliases reuse existing taxonomy" \
        "Arts and Crafts" \
        "$(canonicalize_archive_category "Arts & Crafts" "$structure")"
    assert_equal "subcategory aliases reuse existing punctuation" \
        "Keyrings & Keychains" \
        "$(canonicalize_archive_subcategory "Keyrings and Keychains" "Personal Accessories" "$structure")"
    local alias_only_structure
    alias_only_structure='{
        "categories": [{
            "name": "Toys & Games & Characters",
            "subcategories": []
        }]
    }'
    assert_equal "alias-only taxonomies are reused instead of duplicated" \
        "Toys & Games & Characters" \
        "$(canonicalize_archive_category "Toys Games And Characters" "$alias_only_structure")"
    assert_equal "dot traversal is rejected as a folder component" \
        "Unsorted Project" \
        "$(sanitize_folder_component "..")"
    assert_equal "persisted dot traversal is rejected as a folder component" \
        "Unsorted Project" \
        "$(sanitize_existing_folder_component "..")"
    assert_false "archive destinations cannot escape the archive root" \
        is_safe_archive_destination "$BASE_PATH/../escaped-project"
}

test_case_only_rename() {
    log_divider() { :; }
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }

    local tmp_dir
    tmp_dir=$(command mktemp -d)
    INPUT_PATH="$tmp_dir/input"
    STATE_FILE="$tmp_dir/state.json"
    command mkdir -p "$INPUT_PATH"
    print -r -- "notes" >"$INPUT_PATH/print notes.txt"
    command mkdir -p "$INPUT_PATH/files/stls"
    print -r -- "model" >"$INPUT_PATH/files/stls/model.stl"
    command jq -n '{
        metadata: {duplicates: []},
        files: [
            {
                id: 0,
                relativePath: "print notes.txt",
                proposed: {
                    path: null,
                    folder: ".",
                    filename: "Print Notes.txt"
                }
            },
            {
                id: 1,
                relativePath: "files/stls/model.stl",
                proposed: {
                    path: "files/STLs/Model.stl",
                    folder: null,
                    filename: null
                }
            }
        ]
    }' >"$STATE_FILE"

    apply_rename_plan

    assert_equal "case-only rename records the desired casing" \
        "Print Notes.txt" \
        "$(command jq -r '.files[0].appliedPath' "$STATE_FILE")"
    assert_equal "case-only rename updates the on-disk basename" \
        "Print Notes.txt" \
        "$(command find "$INPUT_PATH" -maxdepth 1 -type f -exec basename {} \;)"
    assert_equal "case-only rename records parent-directory casing" \
        "files/STLs/Model.stl" \
        "$(command jq -r '.files[1].appliedPath' "$STATE_FILE")"
    assert_equal "case-only rename updates parent-directory casing on disk" \
        "./Print Notes.txt
./files/STLs/Model.stl" \
        "$(cd "$INPUT_PATH" && command find . -type f | LC_ALL=C command sort)"

    command rm -rf "$tmp_dir"
}

test_malformed_archive_cache_rebuild() {
    local tmp_dir prior_cache_dir cache_key cache_file structure
    tmp_dir=$(command mktemp -d)
    prior_cache_dir="$CACHE_DIR"
    CACHE_DIR="$tmp_dir/cache"
    command mkdir -p "$CACHE_DIR" "$tmp_dir/archive/Category/Subcategory"
    print -r -- "model" >"$tmp_dir/archive/Category/Subcategory/model.stl"
    cache_key=$(printf '%s' "$tmp_dir/archive" | command cksum | command awk '{print $1}')
    cache_file="$CACHE_DIR/archive-structure-$cache_key.json"
    print -r -- '{"categories":[7]}' >"$cache_file"

    structure=$(get_folder_structure "$tmp_dir/archive")

    if command jq -e '
        .categories == [{
            name: "Category",
            subcategories: [{name: "Subcategory", itemCount: 1}]
        }]
    ' <<<"$structure" >/dev/null; then
        pass "malformed archive cache is rebuilt from disk"
    else
        fail "malformed archive cache is rebuilt from disk"
    fi

    CACHE_DIR="$prior_cache_dir"
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

ORGANIZE_3D_LIBRARY_ONLY=1 source "$ORGANIZER"

test_agent_plan_boundary
test_deterministic_normalization_and_taxonomy
test_case_only_rename
test_malformed_archive_cache_rebuild
test_external_recovery_and_relative_state
test_model_capabilities

print -r -- ""
print -r -- "Passed: $PASSED"
print -r -- "Failed: $FAILED"
((FAILED == 0))
