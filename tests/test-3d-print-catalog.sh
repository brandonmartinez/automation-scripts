#!/usr/bin/env zsh

set -o errexit
set -o nounset
set -o pipefail
setopt null_glob

readonly TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
readonly ORGANIZER="$REPO_ROOT/organization/organize-3d-imports.sh"
readonly CATALOG_FUNCTIONS="$REPO_ROOT/organization/3d-print-catalog-functions.sh"
readonly CATALOG_MANAGER="$REPO_ROOT/organization/manage-3d-print-catalog.sh"
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

assert_sql() {
    local description="$1"
    local expected="$2"
    local db="$3"
    local query="$4"
    local actual
    actual=$(command sqlite3 "$db" "$query")
    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '$actual')"
    fi
}

assert_jq() {
    local description="$1"
    local expression="$2"
    local file="$3"
    if command jq -e "$expression" "$file" >/dev/null; then
        pass "$description"
    else
        fail "$description ($(command jq -c . "$file" 2>/dev/null || print -r -- "invalid JSON"))"
    fi
}

tmp_dir=$(command mktemp -d)
trap 'command rm -rf "$tmp_dir"' EXIT
archive="$tmp_dir/archive"
recovery="$tmp_dir/recovery"
catalog_db="$archive/.3d-print-catalog.sqlite3"
catalog_html="$archive/3D Print Catalog.html"
catalog_health="$archive/.3d-print-catalog-health.json"
first_import="$tmp_dir/drop/Project One"
duplicate_import="$tmp_dir/drop/Duplicate Project"
command mkdir -p "$first_import" "$duplicate_import"
print -r -- "same model" >"$first_import/model.stl"
print -r -- "same model" >"$duplicate_import/model.stl"

run_organizer() {
    local source_path="$1"
    ORGANIZE_3D_BASE_PATH="$archive" \
        ORGANIZE_3D_RECOVERY_DIR="$recovery" \
        ORGANIZE_3D_CATALOG_DB="$catalog_db" \
        ORGANIZE_3D_CATALOG_HTML="$catalog_html" \
        ORGANIZE_3D_CATALOG_HEALTH="$catalog_health" \
        ORGANIZE_3D_NO_REVEAL=1 \
        command zsh "$ORGANIZER" --skip-ai "$source_path" >/dev/null 2>&1
}

run_organizer "$first_import"
first_project="$archive/Unsorted/Needs Review/Project One"
assert_true "first import is archived normally" test -d "$first_project"
assert_sql "go-forward import creates one catalog project" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM projects;"
assert_sql "go-forward import catalogs its file hash" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM files WHERE length(sha256) = 64;"
assert_true "go-forward import atomically renders the HTML browser" test -f "$catalog_html"
assert_jq "go-forward import writes a healthy catalog report" \
    '.healthy == true and .counts.projects == 1 and .counts.files == 1' "$catalog_health"

run_organizer "$duplicate_import"
assert_true "exact duplicate does not create a numbered archive project" \
    test ! -e "$archive/Unsorted/Needs Review/Duplicate Project"
assert_true "exact duplicate does not create a parenthesized archive project" \
    test ! -e "$archive/Unsorted/Needs Review/Duplicate Project (2)"
assert_sql "exact duplicate does not add another catalog project" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM projects;"
assert_sql "exact duplicate records a durable catalog event" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM import_events WHERE outcome = 'exact-duplicate';"
duplicate_receipt=$(command find "$recovery" -name duplicate-import.json -type f -print -quit)
assert_true "exact duplicate retains a recovery receipt" test -f "$duplicate_receipt"
assert_jq "duplicate receipt points to the canonical archived project" \
    '.metadata.archivePlan.disposition == "exact-duplicate" and .metadata.archivePlan.destinationPath == "Unsorted/Needs Review/Project One"' \
    "$duplicate_receipt"
assert_true "exact duplicate retains a valid recovery archive" \
    command unzip -tq "${duplicate_receipt:h}/source.zip"

late_import="$tmp_dir/drop/Late Source Change"
late_project="$archive/Unsorted/Needs Review/Late Source Change"
fake_unzip_dir="$tmp_dir/fake-unzip"
command mkdir -p "$late_import" "$fake_unzip_dir"
print -r -- "same model" >"$late_import/model.stl"
command cat >"$fake_unzip_dir/unzip" <<'FAKE_UNZIP'
#!/usr/bin/env zsh
print -r -- "late model" >"$LATE_SOURCE_PATH/late-added.stl"
exec "$REAL_UNZIP" "$@"
FAKE_UNZIP
command chmod +x "$fake_unzip_dir/unzip"
LATE_SOURCE_PATH="$late_import" \
    REAL_UNZIP="$(whence -p unzip)" \
    PATH="$fake_unzip_dir:$PATH" \
    ORGANIZE_3D_BASE_PATH="$archive" \
    ORGANIZE_3D_RECOVERY_DIR="$recovery" \
    ORGANIZE_3D_CATALOG_DB="$catalog_db" \
    ORGANIZE_3D_CATALOG_HTML="$catalog_html" \
    ORGANIZE_3D_CATALOG_HEALTH="$catalog_health" \
    ORGANIZE_3D_NO_REVEAL=1 \
    command zsh "$ORGANIZER" --skip-ai "$late_import" >/dev/null 2>&1
assert_true "a source changed after backup is preserved instead of suppressed" \
    test -f "$late_project/late-added.stl"
command rm -rf "$late_project"
command sqlite3 "$catalog_db" "
    DELETE FROM files WHERE project_id = (
        SELECT id FROM projects WHERE relative_path = 'Unsorted/Needs Review/Late Source Change'
    );
    DELETE FROM projects WHERE relative_path = 'Unsorted/Needs Review/Late Source Change';
"

run_organizer "$first_project"
assert_true "reprocessing the canonical project leaves it in place" test -d "$first_project"
assert_true "reprocessing the canonical project does not create a numbered copy" \
    test ! -e "$archive/Unsorted/Needs Review/Project One (2)"
assert_true "reprocessing the canonical project preserves its model" test -f "$first_project/model.stl"
assert_sql "reprocessing the canonical project records a no-op event" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM import_events WHERE outcome = 'already-archived';"

stale_import="$tmp_dir/drop/Stale Catalog Match"
command mkdir -p "$stale_import"
print -r -- "same model" >"$stale_import/model.stl"
print -r -- "changed canonical model" >"$first_project/model.stl"
run_organizer "$stale_import"
assert_true "stale catalog hashes cannot suppress a distinct import" \
    test -d "$archive/Unsorted/Needs Review/Stale Catalog Match"
assert_true "stale catalog hashes cannot delete the modified canonical project" \
    test -f "$first_project/model.stl"
run_organizer "$first_project"
assert_true "stale catalog data cannot move a canonical project to a numbered path" \
    test ! -e "$archive/Unsorted/Needs Review/Project One (2)"
assert_true "planned-destination self-detection preserves the modified model" \
    command grep -Fqx "changed canonical model" "$first_project/model.stl"
assert_sql "planned-destination self-detection records a second no-op event" "2" "$catalog_db" \
    "SELECT COUNT(*) FROM import_events WHERE outcome = 'already-archived';"

export ORGANIZE_3D_BASE_PATH="$archive"
export ORGANIZE_3D_CATALOG_DB="$catalog_db"
export ORGANIZE_3D_CATALOG_HTML="$catalog_html"
export ORGANIZE_3D_CATALOG_HEALTH="$catalog_health"
source "$CATALOG_FUNCTIONS"

overlap_project="$archive/Overlap/Only/Canonical"
overlap_state="$overlap_project/agentic-plan.json"
command mkdir -p "$overlap_project"
print -r -- "overlap model" >"$overlap_project/model.stl"
overlap_hash=$(command shasum -a 256 "$overlap_project/model.stl" | command awk '{print $1}')
overlap_size=$(command stat -f%z "$overlap_project/model.stl" 2>/dev/null ||
    command stat -c%s "$overlap_project/model.stl")
command jq -n --arg hash "$overlap_hash" --arg size "$overlap_size" '{
    metadata: {importId: "overlap", generatedAt: "2026-01-01T00:00:00Z"},
    files: [{
        relativePath: "model.stl",
        filename: "model.stl",
        extension: "stl",
        category: "3d-model",
        sizeBytes: ($size | tonumber),
        sha256: $hash
    }]
}' >"$overlap_state"
index_3d_project_from_state "$overlap_state" "$overlap_project" "valid"
if run_organizer "$archive/Overlap/Only"; then
    fail "overlapping source and canonical paths are rejected"
else
    pass "overlapping source and canonical paths are rejected"
fi
assert_true "overlap rejection preserves canonical archive data" \
    test -f "$overlap_project/model.stl"
command rm -rf "$archive/Overlap"
command sqlite3 "$catalog_db" "
    DELETE FROM files WHERE project_id = (
        SELECT id FROM projects WHERE relative_path = 'Overlap/Only/Canonical'
    );
    DELETE FROM projects WHERE relative_path = 'Overlap/Only/Canonical';
"

malicious_project="$archive/Temporary/Validation/Malicious State"
malicious_state="$malicious_project/agentic-plan.json"
command mkdir -p "$malicious_project"
print -r -- "model" >"$malicious_project/model.stl"
command jq -n '{
    metadata: {},
    files: [{
        relativePath: "model.stl",
        sizeBytes: "0); DROP TABLE import_events; --",
        sha256: ("a" * 64)
    }]
}' >"$malicious_state"
if index_3d_project_from_state "$malicious_state" "$malicious_project" "valid" >/dev/null 2>&1; then
    fail "catalog indexing rejects nonnumeric legacy file sizes"
else
    pass "catalog indexing rejects nonnumeric legacy file sizes"
fi
assert_sql "rejected legacy metadata cannot alter the catalog schema" "1" "$catalog_db" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'import_events';"
command rm -rf "$malicious_project"

version_one="$archive/Models/Versioned/Version One"
version_two="$archive/Models/Versioned/Version Two"
command mkdir -p "$version_one" "$version_two"
print -r -- "version one" >"$version_one/source.webloc"
print -r -- "version two" >"$version_two/source.webloc"
version_one_hash=$(command shasum -a 256 "$version_one/source.webloc" | command awk '{print $1}')
version_two_hash=$(command shasum -a 256 "$version_two/source.webloc" | command awk '{print $1}')
version_one_size=$(command stat -f%z "$version_one/source.webloc" 2>/dev/null ||
    command stat -c%s "$version_one/source.webloc")
version_two_size=$(command stat -f%z "$version_two/source.webloc" 2>/dev/null ||
    command stat -c%s "$version_two/source.webloc")
version_one_state="$version_one/agentic-plan.json"
version_two_state="$version_two/agentic-plan.json"
command jq -n --arg hash "$version_one_hash" --arg size "$version_one_size" '{
    metadata: {
        importId: "version-one",
        generatedAt: "2026-01-01T00:00:00Z",
        archivePlan: {destinationPath: "Models/Versioned/Version One"}
    },
    files: [{
        id: 0,
        relativePath: "source.webloc",
        filename: "source.webloc",
        extension: "webloc",
        category: "documentation",
        sizeBytes: ($size | tonumber),
        sha256: $hash,
        sourceUrl: "https://example.test/model/42"
    }]
}' >"$version_one_state"
command jq -n --arg hash "$version_two_hash" --arg size "$version_two_size" '{
    metadata: {
        importId: "version-two",
        generatedAt: "2026-01-02T00:00:00Z",
        archivePlan: {destinationPath: "Models/Versioned/Version Two"}
    },
    files: [{
        id: 0,
        relativePath: "source.webloc",
        filename: "source.webloc",
        extension: "webloc",
        category: "documentation",
        sizeBytes: ($size | tonumber),
        sha256: $hash,
        sourceUrl: "https://example.test/model/42"
    }]
}' >"$version_two_state"
index_3d_project_from_state "$version_one_state" "$version_one" "valid"

incoming_state="$tmp_dir/incoming-version.json"
command cp "$version_two_state" "$incoming_state"
annotate_3d_catalog_matches "$incoming_state"
assert_jq "same source URL with a changed hash is detected as a version" \
    '.metadata.catalog.versionMatches == 1 and .files[0].catalogMatches[0].relationship == "version" and (.files[0].catalogMatches[0].reasons == ["sourceUrl"])' \
    "$incoming_state"
index_3d_project_from_state "$version_two_state" "$version_two" "valid"

legacy_project="$archive/Legacy/Parts/Legacy Widget"
command mkdir -p "$legacy_project"
print -r -- "legacy cad" >"$legacy_project/widget.FCStd"
legacy_before=$(command shasum -a 256 "$legacy_project/widget.FCStd" | command awk '{print $1}')
incomplete_project="$archive/Legacy/Parts/Incomplete Widget"
command mkdir -p "$incomplete_project"
print -r -- "incomplete mesh" >"$incomplete_project/widget.stl"
command jq -n '{metadata: {}, files: []}' >"$incomplete_project/agentic-plan.json"

ORGANIZE_3D_BASE_PATH="$archive" \
    ORGANIZE_3D_CATALOG_DB="$catalog_db" \
    ORGANIZE_3D_CATALOG_HTML="$catalog_html" \
    ORGANIZE_3D_CATALOG_HEALTH="$catalog_health" \
    command zsh "$CATALOG_MANAGER" rebuild --archive "$archive" >/dev/null 2>&1

legacy_after=$(command shasum -a 256 "$legacy_project/widget.FCStd" | command awk '{print $1}')
if [[ "$legacy_before" == "$legacy_after" && ! -e "$legacy_project/agentic-plan.json" ]]; then
    pass "legacy backfill leaves project contents unchanged"
else
    fail "legacy backfill leaves project contents unchanged"
fi
assert_sql "legacy backfill indexes projects without metadata" "missing-state" "$catalog_db" \
    "SELECT metadata_status FROM projects WHERE relative_path = 'Legacy/Parts/Legacy Widget';"
assert_sql "legacy backfill classifies expanded CAD formats" "3d-model|fcstd" "$catalog_db" \
    "SELECT file_category || '|' || extension FROM files f JOIN projects p ON p.id=f.project_id WHERE p.relative_path='Legacy/Parts/Legacy Widget';"
assert_sql "legacy backfill replaces an incomplete empty inventory" "incomplete-state|1" "$catalog_db" \
    "SELECT p.metadata_status || '|' || COUNT(f.id) FROM projects p LEFT JOIN files f ON p.id=f.project_id WHERE p.relative_path='Legacy/Parts/Incomplete Widget' GROUP BY p.id;"
assert_jq "health report identifies legacy metadata and source URL versions" \
    '.healthy == true and .counts.legacyProjectsWithoutCanonicalMetadata == 2 and .counts.versionSourceUrlGroups == 1' \
    "$catalog_health"
if command grep -Fq "<title>3D Print Catalog</title>" "$catalog_html" &&
    command grep -Fq "Search projects, categories, formats, URLs, or hashes" "$catalog_html" &&
    command grep -Fq 'project.path.split("/").map(encodeURIComponent)' "$catalog_html"; then
    pass "static catalog browser contains searchable UI"
else
    fail "static catalog browser contains searchable UI"
fi

saved_db="$THREE_D_CATALOG_DB"
saved_html="$THREE_D_CATALOG_HTML"
saved_health="$THREE_D_CATALOG_HEALTH"
broken_db="$tmp_dir/not-a-database.sqlite3"
preserved_html="$tmp_dir/preserved-catalog.html"
preserved_health="$tmp_dir/preserved-health.json"
print -r -- "not a database" >"$broken_db"
print -r -- "preserve html" >"$preserved_html"
print -r -- '{"preserve":"health"}' >"$preserved_health"
THREE_D_CATALOG_DB="$broken_db"
THREE_D_CATALOG_HTML="$preserved_html"
THREE_D_CATALOG_HEALTH="$preserved_health"
if render_3d_catalog_html >/dev/null 2>&1; then
    fail "failed catalog rendering reports failure"
else
    pass "failed catalog rendering reports failure"
fi
assert_true "failed catalog rendering preserves the previous HTML" \
    command grep -Fxq "preserve html" "$preserved_html"
if write_3d_catalog_health_report >/dev/null 2>&1; then
    fail "failed health generation reports failure"
else
    pass "failed health generation reports failure"
fi
assert_jq "failed health generation preserves the previous report" \
    '.preserve == "health"' "$preserved_health"
THREE_D_CATALOG_DB="$saved_db"
THREE_D_CATALOG_HTML="$saved_html"
THREE_D_CATALOG_HEALTH="$saved_health"

project_count_before_failed_rebuild=$(command sqlite3 "$catalog_db" 'SELECT COUNT(*) FROM projects;')
fake_find_dir="$tmp_dir/fake-find"
command mkdir -p "$fake_find_dir"
command cat >"$fake_find_dir/find" <<'FAKE_FIND'
#!/usr/bin/env zsh
exit 1
FAKE_FIND
command chmod +x "$fake_find_dir/find"
if PATH="$fake_find_dir:$PATH" \
    ORGANIZE_3D_BASE_PATH="$archive" \
    ORGANIZE_3D_CATALOG_DB="$catalog_db" \
    ORGANIZE_3D_CATALOG_HTML="$catalog_html" \
    ORGANIZE_3D_CATALOG_HEALTH="$catalog_health" \
    command zsh "$CATALOG_MANAGER" rebuild --archive "$archive" >/dev/null 2>&1; then
    fail "failed archive discovery prevents catalog replacement"
else
    pass "failed archive discovery prevents catalog replacement"
fi
assert_sql "failed archive discovery preserves the previous catalog" \
    "$project_count_before_failed_rebuild" "$catalog_db" "SELECT COUNT(*) FROM projects;"

command rm -f "$legacy_project/widget.FCStd"
ORGANIZE_3D_BASE_PATH="$archive" \
    ORGANIZE_3D_CATALOG_DB="$catalog_db" \
    ORGANIZE_3D_CATALOG_HEALTH="$catalog_health" \
    command zsh "$CATALOG_MANAGER" health --archive "$archive" >/dev/null 2>&1
assert_jq "health report detects stale catalog file records" \
    '.healthy == false and .counts.missingCatalogedFiles == 1' "$catalog_health"

print -r -- ""
print -r -- "Passed: $PASSED"
print -r -- "Failed: $FAILED"
((FAILED == 0))
