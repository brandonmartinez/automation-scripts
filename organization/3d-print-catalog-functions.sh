#!/usr/bin/env zsh

if [[ -n "${THREE_D_PRINT_CATALOG_LOADED:-}" ]]; then
    return 0
fi
THREE_D_PRINT_CATALOG_LOADED=1

THREE_D_CATALOG_BASE="${ORGANIZE_3D_BASE_PATH:-$HOME/Documents/3D Prints}"
THREE_D_CATALOG_DB="${ORGANIZE_3D_CATALOG_DB:-$THREE_D_CATALOG_BASE/.3d-print-catalog.sqlite3}"
THREE_D_CATALOG_HTML="${ORGANIZE_3D_CATALOG_HTML:-$THREE_D_CATALOG_BASE/3D Print Catalog.html}"
THREE_D_CATALOG_HEALTH="${ORGANIZE_3D_CATALOG_HEALTH:-$THREE_D_CATALOG_BASE/.3d-print-catalog-health.json}"

catalog_sql_quote() {
    local value="$1"
    local quote="'"
    value="${value//$quote/$quote$quote}"
    printf "'%s'" "$value"
}

catalog_sql_nullable() {
    local value="$1"
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' "NULL"
    else
        catalog_sql_quote "$value"
    fi
}

validate_3d_catalog_state() {
    local state_file="$1"
    [[ -f "$state_file" ]] || return 1
    command jq -e '
        (.metadata | type) == "object" and
        (.files | type) == "array" and
        all(.files[];
            (((.appliedPath // .relativePath // "") | type) == "string") and
            (((.appliedPath // .relativePath // "") | length) > 0) and
            ((.sizeBytes | type) == "number") and
            (.sizeBytes >= 0) and
            (.sizeBytes == (.sizeBytes | floor)) and
            (.sizeBytes < 9007199254740992) and
            ((.sha256 | type) == "string") and
            (.sha256 | test("^[0-9a-f]{64}$")) and
            (((.sourceUrl // "") | type) == "string")
        )
    ' "$state_file" >/dev/null 2>&1
}

initialize_3d_catalog() {
    command mkdir -p "$(dirname "$THREE_D_CATALOG_DB")"
    command sqlite3 "$THREE_D_CATALOG_DB" >/dev/null <<'SQL'
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY,
    import_id TEXT,
    relative_path TEXT NOT NULL UNIQUE,
    category TEXT NOT NULL,
    subcategory TEXT NOT NULL,
    name TEXT NOT NULL,
    state_file TEXT,
    metadata_status TEXT NOT NULL,
    generated_at TEXT,
    indexed_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL,
    filename TEXT NOT NULL,
    extension TEXT NOT NULL,
    file_category TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    source_url TEXT,
    UNIQUE(project_id, relative_path)
);
CREATE TABLE IF NOT EXISTS import_events (
    id INTEGER PRIMARY KEY,
    import_id TEXT NOT NULL,
    outcome TEXT NOT NULL,
    project_relative_path TEXT,
    matched_project_relative_path TEXT,
    recorded_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS files_sha256_idx ON files(sha256);
CREATE INDEX IF NOT EXISTS files_source_url_idx ON files(source_url);
CREATE INDEX IF NOT EXISTS import_events_import_id_idx ON import_events(import_id);
SQL
}

index_3d_project_from_state() {
    local state_file="$1"
    local project_path="$2"
    local metadata_status="${3:-valid}"
    [[ -f "$state_file" && -d "$project_path" ]] || return 1
    validate_3d_catalog_state "$state_file" || return 1

    local project_relative category subcategory project_name import_id generated_at state_relative indexed_at
    project_relative="${project_path#$THREE_D_CATALOG_BASE/}"
    [[ "$project_relative" != "$project_path" ]] || return 1
    category="${project_relative%%/*}"
    local remainder="${project_relative#*/}"
    subcategory="${remainder%%/*}"
    project_name="${project_relative:t}"
    import_id=$(command jq -r '.metadata.importId // empty' "$state_file")
    generated_at=$(command jq -r '.metadata.generatedAt // empty' "$state_file")
    state_relative="${state_file#$THREE_D_CATALOG_BASE/}"
    [[ "$state_relative" != "$state_file" ]] || state_relative=""
    indexed_at=$(date -Iseconds)

    local sql_file
    sql_file=$(command mktemp -t 3d-catalog.XXXXXX.sql)
    {
        printf '%s\n' "PRAGMA foreign_keys = ON;"
        printf '%s\n' "BEGIN IMMEDIATE;"
        printf "INSERT INTO projects(import_id, relative_path, category, subcategory, name, state_file, metadata_status, generated_at, indexed_at) VALUES(%s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT(relative_path) DO UPDATE SET import_id=excluded.import_id, category=excluded.category, subcategory=excluded.subcategory, name=excluded.name, state_file=excluded.state_file, metadata_status=excluded.metadata_status, generated_at=excluded.generated_at, indexed_at=excluded.indexed_at;\n" \
            "$(catalog_sql_nullable "$import_id")" \
            "$(catalog_sql_quote "$project_relative")" \
            "$(catalog_sql_quote "$category")" \
            "$(catalog_sql_quote "$subcategory")" \
            "$(catalog_sql_quote "$project_name")" \
            "$(catalog_sql_nullable "$state_relative")" \
            "$(catalog_sql_quote "$metadata_status")" \
            "$(catalog_sql_nullable "$generated_at")" \
            "$(catalog_sql_quote "$indexed_at")"
        printf "DELETE FROM files WHERE project_id = (SELECT id FROM projects WHERE relative_path = %s);\n" \
            "$(catalog_sql_quote "$project_relative")"

        if ! command jq -r --arg project "$project_relative" --arg quote "'" '
            def sqlq:
                $quote + gsub($quote; $quote + $quote) + $quote;
            .files[] |
            (.appliedPath // .relativePath) as $path |
            (($path // .filename) | split("/")[-1]) as $filename |
            (
                if (.sourceUrl // "") == ""
                then "NULL"
                else (.sourceUrl | sqlq)
                end
            ) as $source_url |
            "INSERT INTO files(project_id, relative_path, filename, extension, file_category, size_bytes, sha256, source_url) SELECT id, \(($path | sqlq)), \(($filename | sqlq)), \(((.extension // "") | sqlq)), \(((.category // "other") | sqlq)), \(.sizeBytes), \((.sha256 | sqlq)), \($source_url) FROM projects WHERE relative_path = \(($project | sqlq));"
        ' "$state_file"; then
            command rm -f "$sql_file"
            return 1
        fi
        printf '%s\n' "COMMIT;"
    } >"$sql_file"

    if ! command sqlite3 -bail "$THREE_D_CATALOG_DB" <"$sql_file"; then
        command rm -f "$sql_file"
        return 1
    fi
    command rm -f "$sql_file"
}

record_3d_catalog_event() {
    local import_id="$1"
    local outcome="$2"
    local project_relative="${3:-}"
    local matched_relative="${4:-}"
    local recorded_at
    recorded_at=$(date -Iseconds)
    command sqlite3 "$THREE_D_CATALOG_DB" \
        "INSERT INTO import_events(import_id, outcome, project_relative_path, matched_project_relative_path, recorded_at) VALUES($(catalog_sql_quote "$import_id"), $(catalog_sql_quote "$outcome"), $(catalog_sql_nullable "$project_relative"), $(catalog_sql_nullable "$matched_relative"), $(catalog_sql_quote "$recorded_at"));"
}

export_3d_catalog_files_json() {
    local output_file="$1"
    local tmp="$output_file.tmp.$$"
    if ! command sqlite3 -json "$THREE_D_CATALOG_DB" '
        SELECT
            p.relative_path AS projectPath,
            p.category AS projectCategory,
            p.subcategory AS projectSubcategory,
            p.name AS projectName,
            f.relative_path AS filePath,
            f.sha256 AS sha256,
            f.source_url AS sourceUrl
        FROM files f
        JOIN projects p ON p.id = f.project_id
        ORDER BY p.relative_path, f.relative_path;
    ' >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    [[ -s "$tmp" ]] || print -r -- '[]' >"$tmp"
    command mv "$tmp" "$output_file"
}

annotate_3d_catalog_matches() {
    local state_file="$1"
    initialize_3d_catalog

    local catalog_json tmp
    catalog_json=$(command mktemp -t 3d-catalog-files.XXXXXX.json)
    tmp="$state_file.tmp.$$"
    export_3d_catalog_files_json "$catalog_json"

    if ! command jq --slurpfile archived "$catalog_json" '
        ($archived[0] // []) as $catalog |
        (.files // []) as $incoming |
        .files |= map(
            . as $current |
            .catalogMatches = [
                $catalog[]
                | select(
                    (.sha256 == $current.sha256) or
                    (
                        (.sourceUrl // "") != "" and
                        (.sourceUrl == ($current.sourceUrl // ""))
                    )
                )
                | {
                    projectPath,
                    filePath,
                    relationship: (
                        if .sha256 == $current.sha256 then "duplicate"
                        else "version"
                        end
                    ),
                    reasons: (
                        [
                            if .sha256 == $current.sha256 then "sha256" else empty end,
                            if (.sourceUrl // "") != "" and .sourceUrl == ($current.sourceUrl // "") then "sourceUrl" else empty end
                        ]
                    )
                }
            ]
        ) |
        .metadata.catalog = {
            matchedFiles: ([.files[] | select((.catalogMatches | length) > 0)] | length),
            duplicateMatches: ([.files[].catalogMatches[] | select(.relationship == "duplicate")] | length),
            versionMatches: ([.files[].catalogMatches[] | select(.relationship == "version")] | length),
            exactDuplicateProject: (
                [
                    $catalog
                    | group_by(.projectPath)[]
                    | select(
                        ([.[].sha256] | sort) == ([$incoming[].sha256] | sort)
                    )
                    | .[0]
                    | {
                        relativePath: .projectPath,
                        category: .projectCategory,
                        subcategory: .projectSubcategory,
                        folderName: .projectName
                    }
                ][0] // null
            )
        }
    ' "$state_file" >"$tmp"; then
        command rm -f "$catalog_json" "$tmp"
        return 1
    fi
    command mv "$tmp" "$state_file"
    command rm -f "$catalog_json"
}

render_3d_catalog_html() {
    initialize_3d_catalog || return 1
    local catalog_json encoded generated_at generated_at_json tmp
    if ! catalog_json=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" "
        SELECT COALESCE(json_group_array(json(project_json)), '[]')
        FROM (
            SELECT json_object(
                'path', p.relative_path,
                'category', p.category,
                'subcategory', p.subcategory,
                'name', p.name,
                'metadataStatus', p.metadata_status,
                'generatedAt', p.generated_at,
                'indexedAt', p.indexed_at,
                'files', json(COALESCE((
                    SELECT json_group_array(json_object(
                        'path', f.relative_path,
                        'name', f.filename,
                        'extension', f.extension,
                        'category', f.file_category,
                        'sizeBytes', f.size_bytes,
                        'sha256', f.sha256,
                        'sourceUrl', f.source_url
                    ))
                    FROM files f
                    WHERE f.project_id = p.id
                    ORDER BY f.relative_path
                ), '[]'))
            ) AS project_json
            FROM projects p
            ORDER BY p.category, p.subcategory, p.name
        );
    "); then
        return 1
    fi
    if ! command jq -e 'type == "array"' >/dev/null 2>&1 <<<"$catalog_json"; then
        return 1
    fi
    if ! encoded=$(printf '%s' "$catalog_json" | command base64 | command tr -d '\n'); then
        return 1
    fi
    generated_at=$(date -Iseconds)
    if ! generated_at_json=$(printf '%s' "$generated_at" | command jq -R .); then
        return 1
    fi
    tmp="$THREE_D_CATALOG_HTML.tmp.$$"
    command mkdir -p "$(dirname "$THREE_D_CATALOG_HTML")" || return 1
    if ! {
        command cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>3D Print Catalog</title>
<style>
:root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { margin: 0; background: #111827; color: #e5e7eb; }
header { position: sticky; top: 0; z-index: 2; padding: 1.25rem max(1rem, 5vw); background: #111827ee; border-bottom: 1px solid #374151; backdrop-filter: blur(12px); }
h1 { margin: 0 0 .75rem; font-size: 1.5rem; }
#summary { color: #9ca3af; margin-bottom: .75rem; }
input { width: min(44rem, 100%); box-sizing: border-box; padding: .8rem 1rem; border-radius: .65rem; border: 1px solid #4b5563; background: #1f2937; color: inherit; font-size: 1rem; }
main { padding: 1.25rem max(1rem, 5vw) 4rem; display: grid; gap: 1rem; }
article { border: 1px solid #374151; border-radius: .8rem; padding: 1rem; background: #1f2937; }
h2 { margin: 0; font-size: 1.1rem; }
h2 a { color: #93c5fd; text-decoration: none; }
.meta { color: #9ca3af; margin: .35rem 0 .8rem; font-size: .9rem; }
details { border-top: 1px solid #374151; padding-top: .7rem; }
li { margin: .35rem 0; overflow-wrap: anywhere; }
.badge { display: inline-block; padding: .08rem .4rem; margin-left: .35rem; border-radius: 999px; background: #374151; font-size: .75rem; }
.empty { color: #9ca3af; }
</style>
</head>
<body>
<header>
<h1>3D Print Catalog</h1>
<div id="summary"></div>
<input id="search" type="search" placeholder="Search projects, categories, formats, URLs, or hashes" autofocus>
</header>
<main id="projects"></main>
<script>
HTML_HEAD
        printf 'const catalogBytes = Uint8Array.from(atob("%s"), character => character.charCodeAt(0));\n' "$encoded"
        printf 'const catalog = JSON.parse(new TextDecoder().decode(catalogBytes));\n'
        printf 'const generatedAt = %s;\n' "$generated_at_json"
        command cat <<'HTML_SCRIPT'
const root = document.getElementById("projects");
const search = document.getElementById("search");
const summary = document.getElementById("summary");
const fileCount = catalog.reduce((count, project) => count + project.files.length, 0);
summary.textContent = `${catalog.length} projects · ${fileCount} files · generated ${generatedAt}`;
function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}
function render(query = "") {
  const needle = query.trim().toLowerCase();
  const matches = catalog.filter(project => JSON.stringify(project).toLowerCase().includes(needle));
  root.innerHTML = matches.length ? matches.map(project => {
    const files = project.files.map(file => `<li><strong>${escapeHtml(file.name)}</strong><span class="badge">${escapeHtml(file.extension || "file")}</span><br><small>${escapeHtml(file.path)} · ${escapeHtml(file.sha256.slice(0, 12))}</small></li>`).join("");
    const projectHref = "./" + project.path.split("/").map(encodeURIComponent).join("/") + "/";
    return `<article><h2><a href="${projectHref}">${escapeHtml(project.name)}</a></h2><div class="meta">${escapeHtml(project.category)} / ${escapeHtml(project.subcategory)} · ${project.files.length} files · ${escapeHtml(project.metadataStatus)}</div><details><summary>Files</summary><ul>${files}</ul></details></article>`;
  }).join("") : '<p class="empty">No matching projects.</p>';
}
search.addEventListener("input", event => render(event.target.value));
render();
</script>
</body>
</html>
HTML_SCRIPT
    } >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    if ! command mv "$tmp" "$THREE_D_CATALOG_HTML"; then
        command rm -f "$tmp"
        return 1
    fi
}

write_3d_catalog_health_report() {
    initialize_3d_catalog || return 1
    local projects files legacy missing_projects missing_files duplicate_hashes duplicate_urls version_urls
    local project_rows file_rows generated_at tmp
    projects=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" 'SELECT COUNT(*) FROM projects;') || return 1
    files=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" 'SELECT COUNT(*) FROM files;') || return 1
    legacy=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" "SELECT COUNT(*) FROM projects WHERE metadata_status != 'valid';") || return 1
    duplicate_hashes=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" 'SELECT COUNT(*) FROM (SELECT sha256 FROM files GROUP BY sha256 HAVING COUNT(*) > 1);') || return 1
    duplicate_urls=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" "SELECT COUNT(*) FROM (SELECT source_url FROM files WHERE source_url IS NOT NULL GROUP BY source_url HAVING COUNT(*) > 1 AND COUNT(DISTINCT sha256) = 1);") || return 1
    version_urls=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" "SELECT COUNT(*) FROM (SELECT source_url FROM files WHERE source_url IS NOT NULL GROUP BY source_url HAVING COUNT(DISTINCT sha256) > 1);") || return 1
    project_rows=$(command sqlite3 -batch "$THREE_D_CATALOG_DB" 'SELECT relative_path FROM projects ORDER BY relative_path;') || return 1
    file_rows=$(command sqlite3 -batch -separator $'\x1f' "$THREE_D_CATALOG_DB" '
        SELECT p.relative_path, f.relative_path
        FROM files f JOIN projects p ON p.id = f.project_id
        ORDER BY p.relative_path, f.relative_path;
    ') || return 1

    missing_projects=0
    missing_files=0
    local project_relative file_relative
    while IFS= read -r project_relative; do
        [[ -n "$project_relative" ]] || continue
        [[ -d "$THREE_D_CATALOG_BASE/$project_relative" ]] || missing_projects=$((missing_projects + 1))
    done <<<"$project_rows"
    while IFS=$'\x1f' read -r project_relative file_relative; do
        [[ -n "$project_relative" && -n "$file_relative" ]] || continue
        [[ -f "$THREE_D_CATALOG_BASE/$project_relative/$file_relative" ]] || missing_files=$((missing_files + 1))
    done <<<"$file_rows"

    generated_at=$(date -Iseconds)
    tmp="$THREE_D_CATALOG_HEALTH.tmp.$$"
    if ! command jq -n \
        --arg generated "$generated_at" \
        --arg projects "$projects" \
        --arg files "$files" \
        --arg legacy "$legacy" \
        --arg missing_projects "$missing_projects" \
        --arg missing_files "$missing_files" \
        --arg duplicate_hashes "$duplicate_hashes" \
        --arg duplicate_urls "$duplicate_urls" \
        --arg version_urls "$version_urls" \
        '{
            schemaVersion: "1.0",
            generatedAt: $generated,
            counts: {
                projects: ($projects | tonumber),
                files: ($files | tonumber),
                legacyProjectsWithoutCanonicalMetadata: ($legacy | tonumber),
                missingProjectDirectories: ($missing_projects | tonumber),
                missingCatalogedFiles: ($missing_files | tonumber),
                duplicateContentGroups: ($duplicate_hashes | tonumber),
                duplicateSourceUrlGroups: ($duplicate_urls | tonumber),
                versionSourceUrlGroups: ($version_urls | tonumber)
            },
            healthy: (
                ($missing_projects | tonumber) == 0 and
                ($missing_files | tonumber) == 0
            )
        }' >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    if ! command jq -e '.schemaVersion == "1.0" and (.healthy | type) == "boolean"' "$tmp" >/dev/null 2>&1; then
        command rm -f "$tmp"
        return 1
    fi
    if ! command mv "$tmp" "$THREE_D_CATALOG_HEALTH"; then
        command rm -f "$tmp"
        return 1
    fi
}

apply_3d_project_finder_tags() {
    local project_path="$1"
    local category="$2"
    local subcategory="$3"
    [[ "${ORGANIZE_3D_APPLY_FINDER_TAGS:-0}" == "1" ]] || return 0

    local json_file binary_file hex
    json_file=$(command mktemp -t 3d-tags.XXXXXX.json)
    binary_file=$(command mktemp -t 3d-tags.XXXXXX.plist)
    command jq -n --arg category "$category" --arg subcategory "$subcategory" \
        '["3D Print", $category, $subcategory] | unique' >"$json_file"
    if ! command plutil -convert binary1 -o "$binary_file" "$json_file" >/dev/null 2>&1; then
        command rm -f "$json_file" "$binary_file"
        return 1
    fi
    hex=$(command xxd -p "$binary_file" | command tr -d '\n')
    command rm -f "$json_file" "$binary_file"
    command xattr -wx com.apple.metadata:_kMDItemUserTags "$hex" "$project_path"
}
