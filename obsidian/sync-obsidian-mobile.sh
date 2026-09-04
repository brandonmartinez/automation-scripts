#!/usr/bin/env zsh
# sync-obsidian-mobile.sh — mirror the git-backed Obsidian vault into the
# Obsidian iCloud container so the vault is readable from Obsidian iOS.
#
# The vault's source of truth is a private GitHub repo at ~/src/brandonmartinez-secondbrain.
# The Obsidian iOS app cannot use a git remote directly, so this script
# maintains a *plain-files* mirror in iCloud Drive. Crucially `.git/` is NEVER
# mirrored — that is what makes this safe, where the usual "keep your vault in
# iCloud" advice is not: iCloud is well documented to corrupt `.git`
# directories.
#
# ONE WAY ONLY: repo -> iCloud. The mirror is a *replica*, not a peer. Nothing
# is ever read back out of iCloud. This replaced an earlier bidirectional
# design whose deletion arbitration (git ledger + a private seen-paths file)
# cost far more than the rare mobile edit was worth.
#
# THE PRACTICAL CONSEQUENCE: edits made in Obsidian on iOS are DISCARDED on the
# next run — overwritten if the note also changed in the repo, deleted outright
# if the note exists only on the phone. Treat mobile as read-only. To capture
# something from the phone, put it somewhere that is not this vault (Apple
# Notes, Drafts, a scratch file outside the mirror) and move it into the repo on
# the desktop. Vault settings are likewise desktop-authoritative: `.obsidian/`
# is published outward, and a settings change made on the phone is reverted on
# the next run. Per-device UI state (workspace*, graph.json) is excluded so each
# device keeps its own pane layout.
#
# SAFETY PROPERTIES
#   * Dry run by default. Nothing is written unless --apply is passed.
#   * Excluded paths are protected from --delete (we deliberately do NOT use
#     --delete-excluded). That is what keeps the phone's workspace-mobile.json
#     alive even though no such file exists on the desktop.
#   * A GNU rsync (nix/homebrew), if present, gets --backup-dir so anything the
#     mirror loses — an overwrite or a --delete — lands in
#     <repo>/_private/mobile-sync-backups/<date>/ and stays recoverable.
#     macOS's bundled openrsync lacks that flag, so on stock macOS a clobbered
#     mobile edit is simply gone.
#   * The repo is never written to, so no run can dirty the working tree.
#   * flock-style lock dir prevents overlapping runs from the launchd timer.
#
# PRIVACY / ENCRYPTION NOTE  (re-read this before changing the exclude list)
#   The `_archive/` tier is the git-crypt deep archive. It is encrypted *in
#   git only* — on local disk it is PLAINTEXT. Mirroring it therefore uploads
#   readable copies. That is acceptable *only* because iCloud Advanced Data
#   Protection is enabled on this account, which makes iCloud Drive
#   end-to-end encrypted (Apple holds no key). If ADP is ever turned off,
#   switch this back to --no-archives.
#
# ---------------------------------------------------------------------------
# Install (launchd LaunchAgent — see com.brandonmartinez.sync-obsidian-mobile.plist):
#   ln -sf "$HOME/src/automation-scripts/obsidian/com.brandonmartinez.sync-obsidian-mobile.plist" \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.sync-obsidian-mobile.plist"
#   launchctl bootstrap gui/$(id -u) \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.sync-obsidian-mobile.plist"
# Reload after edits:
#   launchctl bootout  gui/$(id -u)/com.brandonmartinez.sync-obsidian-mobile 2>/dev/null || true
#   launchctl bootstrap gui/$(id -u) \
#          "$HOME/Library/LaunchAgents/com.brandonmartinez.sync-obsidian-mobile.plist"
#
# Usage:
#   ./sync-obsidian-mobile.sh                 # dry run (archives INCLUDED)
#   ./sync-obsidian-mobile.sh --no-archives   # dry run, notes only (~6 MB)
#   ./sync-obsidian-mobile.sh --apply         # actually sync
#
# Configuration (environment overrides):
#   OBSIDIAN_VAULT_SRC   repo path        (default: ~/src/brandonmartinez-secondbrain)
#   OBSIDIAN_VAULT_DST   iCloud mirror    (default: the Obsidian iCloud container)
#   OBSIDIAN_SYNC_LOG_LEVEL  log verbosity (default: INFO)
# ---------------------------------------------------------------------------

set -o errexit -o nounset -o pipefail

# --- locate repo utilities -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/../utilities/logging.sh"
# Suppress the util's one-time "redirected to..." INFO notice so a routine
# timer run doesn't bury real sync activity.
set_log_level WARN
setup_script_logging "sync-obsidian-mobile"
set_log_level "${OBSIDIAN_SYNC_LOG_LEVEL:-INFO}"

# --- configuration ---------------------------------------------------------
SRC="${OBSIDIAN_VAULT_SRC:-$HOME/src/brandonmartinez-secondbrain}"
DST="${OBSIDIAN_VAULT_DST:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain}"

APPLY=0
WITH_ARCHIVES=1
for arg in "$@"; do
  case "$arg" in
    --apply)         APPLY=1 ;;
    --no-archives)   WITH_ARCHIVES=0 ;;
    --with-archives) WITH_ARCHIVES=1 ;;
    -h|--help)       sed -n '2,68p' "$0"; exit 0 ;;
    *) log_error "unknown flag: $arg"; exit 2 ;;
  esac
done

[[ -d "$SRC" ]] || { log_error "vault repo not found: $SRC"; exit 1; }

# --- single-instance lock --------------------------------------------------
# A slow first run (273 MB into iCloud) can outlast the timer interval; without
# this, a second run would race the first and rsync would fight itself.
LOCK_DIR="${TMPDIR:-/tmp}/sync-obsidian-mobile.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_PID=""
  [[ -f "$LOCK_DIR/pid" ]] && LOCK_PID=$(<"$LOCK_DIR/pid")

  if [[ "$LOCK_PID" == <-> ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log_debug "another sync is already running (pid=$LOCK_PID); exiting"
    exit 0
  fi

  log_warn "removing stale sync lock: $LOCK_DIR"
  command rm -f "$LOCK_DIR/pid"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log_error "could not recover stale sync lock: $LOCK_DIR"
    exit 1
  fi
fi
print -r -- "$$" > "$LOCK_DIR/pid"
cleanup() {
  command rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- pick an rsync ---------------------------------------------------------
# macOS ships openrsync, which lacks --backup-dir. Prefer a real GNU rsync
# (nix/homebrew) when present so anything the mirror loses — an overwritten
# mobile edit, or a file removed by --delete — stays recoverable.
RSYNC=/usr/bin/rsync
BACKUP_ARGS=()
for cand in /run/current-system/sw/bin/rsync /opt/homebrew/bin/rsync; do
  if [[ -x "$cand" ]] && "$cand" --version 2>/dev/null | grep -q '^rsync  *version 3'; then
    RSYNC="$cand"
    BACKUP_ARGS=(--backup --backup-dir="$SRC/_private/mobile-sync-backups/$(date +%Y-%m-%d)")
    break
  fi
done

run_rsync() {
  local phase="$1"
  shift

  local error_file output exit_code
  error_file=$(command mktemp -t sync-obsidian-mobile.XXXXXX)

  if output=$("$RSYNC" "$@" 2>"$error_file"); then
    command rm -f "$error_file"
    printf '%s' "$output"
    return 0
  else
    exit_code=$?
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] && log_error "$phase: $line"
  done < "$error_file"
  command rm -f "$error_file"
  log_error "$phase failed (rsync exit $exit_code)"
  return "$exit_code"
}

# --- what never leaves the repo -------------------------------------------
# Leading slash = anchored at the transfer root. No leading slash = matches at
# any depth, which is what makes the _archive/ rule cover all 24 existing dirs
# *and* every future one automatically.
EXCLUDES=(
  --exclude '.git/'              # never let iCloud near git metadata
  --exclude '/.github/'          # agent/skill tooling, not notes
  --exclude '/_private/'         # gitignored raw pulls (1.4 GB)
  --exclude '/_Meta/Hydration/'  # gitignored scratch (477 MB)
  --exclude '.DS_Store'
  --exclude '.trash/'
)
if [[ $WITH_ARCHIVES -eq 0 ]]; then
  EXCLUDES+=(--exclude '_archive/')   # only when ADP is off — see header
fi

# --- vault config (.obsidian/) --------------------------------------------
# Config is DESKTOP-AUTHORITATIVE. Obsidian mobile writes a much sparser config
# than the desktop app (its app.json had only strictLineBreaks, and its
# daily-notes.json was missing the date format) and rewrites those files on
# launch; publishing the desktop's copy over it on every run is what keeps
# daily-note paths, the attachment folder, and the template folder identical on
# both ends.
#
# Everything in .obsidian/ is shared EXCEPT per-device UI state. workspace*
# covers the desktop's workspace.json AND the phone's separate
# workspace-mobile.json; because these are excluded (and --delete-excluded is
# never used) --delete cannot destroy the phone's saved layout.
CONFIG_EXCLUDES=(
  --exclude '/.obsidian/workspace*'    # per-device pane layout
  --exclude '/.obsidian/graph.json'    # per-device graph view state
)

DRY=(--dry-run)
[[ $APPLY -eq 1 ]] && DRY=()

MODE_DESC=$([[ $APPLY -eq 1 ]] && echo "APPLY" || echo "DRY RUN (nothing written)")
ARCH_DESC=$([[ $WITH_ARCHIVES -eq 1 ]] && echo "included" || echo "excluded")
log_info "➡️  obsidian mobile mirror (repo → iCloud) — mode=$MODE_DESC archives=$ARCH_DESC"
log_debug "repo=$SRC"
log_debug "mirror=$DST"

if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$DST"
elif [[ ! -d "$DST" ]]; then
  log_info "mirror does not exist yet; dry run shows the initial seed"
  DST="${TMPDIR:-/tmp}/obsidian-mirror-empty"
  mkdir -p "$DST"
fi

# --- publish: repo -> iCloud (one way; deletes orphans) -------------------
# The mirror is a replica. Anything present there and absent here is either a
# desktop deletion or a phone-side creation, and both resolve the same way: the
# repo wins and the file goes. That single rule is the whole point of dropping
# the old bidirectional design.
PUBLISH=$(run_rsync "mirror publish" -a "${DRY[@]}" --itemize-changes --delete \
  ${BACKUP_ARGS[@]+"${BACKUP_ARGS[@]}"} \
  "${EXCLUDES[@]}" "${CONFIG_EXCLUDES[@]}" "$SRC/" "$DST/")
SENT=$(printf '%s\n'    "$PUBLISH" | grep -c '^>f' || true)
DELETED=$(printf '%s\n' "$PUBLISH" | grep -c '^\*deleting' || true)

[[ "$SENT" -gt 0 ]] && log_info "➡️  published $SENT file(s) to the mirror" \
                    || log_debug "mirror already up to date"

if [[ "$DELETED" -gt 0 ]]; then
  log_warn "🗑️  removed $DELETED file(s) from the mirror (absent in repo):"
  printf '%s\n' "$PUBLISH" | grep '^\*deleting' | sed -n '1,20p' | while read -r line; do
    log_warn "     ${line#\*deleting }"
  done
fi

if [[ $APPLY -eq 0 ]]; then
  log_info "dry run complete — re-run with --apply to write"
fi
