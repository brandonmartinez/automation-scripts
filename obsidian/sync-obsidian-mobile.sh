#!/usr/bin/env zsh
# sync-obsidian-mobile.sh — mirror the git-backed Obsidian vault into the
# Obsidian iCloud container so the vault is readable/editable from Obsidian iOS.
#
# The vault's source of truth is a private GitHub repo at ~/src/brandonmartinez-secondbrain.
# The Obsidian iOS app cannot use a git remote directly (see the note on
# isomorphic-git below), so this script maintains a *plain-files* mirror in
# iCloud Drive. Crucially `.git/` is NEVER mirrored — that is what makes this
# safe, where the usual "keep your vault in iCloud" advice is not: iCloud is
# well documented to corrupt `.git` directories.
#
# TWO LEGS, AND THE ORDER MATTERS:
#   Leg B (iCloud -> repo)  runs FIRST, --update, never --delete.
#   Leg A (repo -> iCloud)  runs SECOND, with --delete.
# Importing mobile changes first means Leg A's --delete can never mistake a
# phone-created note for an orphan and destroy it before you've seen it.
#
# NOTES ARE TWO-WAY; CONFIG IS ONE-WAY. `.obsidian/` rides Leg A only, so the
# desktop is authoritative for vault settings (daily-note folder + date format,
# attachment folder, template folder, enabled plugins, theme). Obsidian mobile
# writes a much sparser config than the desktop app and rewrites it on launch,
# so letting it back through Leg B would silently strip those settings. The
# practical consequence: change vault settings on the desktop. A settings change
# made on the phone is reverted on the next run. Per-device UI state
# (workspace*, graph.json) is excluded in both directions and each device keeps
# its own.
#
# DELETION ARBITRATION: because Leg B never deletes, a naive implementation
# would resurrect every file you delete on the desktop. git is used as the
# arbiter — a path git tracks that is now missing from disk is a real deletion
# and is withheld from Leg B, so Leg A can clear it from the mirror. A path git
# has never seen is a genuine phone capture and is imported.
#
# SAFETY PROPERTIES
#   * Dry run by default. Nothing is written unless --apply is passed.
#   * Excluded paths are protected from --delete (we deliberately do NOT use
#     --delete-excluded). That is what keeps the phone's workspace-mobile.json
#     alive even though no such file exists on the desktop.
#   * A GNU rsync (nix/homebrew), if present, gets --backup-dir so overwrites
#     are recoverable. macOS's bundled openrsync lacks that flag; on the repo
#     side git is the safety net regardless.
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
    -h|--help)       sed -n '2,56p' "$0"; exit 0 ;;
    *) log_error "unknown flag: $arg"; exit 2 ;;
  esac
done

[[ -d "$SRC" ]] || { log_error "vault repo not found: $SRC"; exit 1; }

# --- single-instance lock --------------------------------------------------
# A slow first run (273 MB into iCloud) can outlast the timer interval; without
# this, a second run would race the first and rsync would fight itself.
LOCK_DIR="${TMPDIR:-/tmp}/sync-obsidian-mobile.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_debug "another sync is already running (lock: $LOCK_DIR); exiting"
  exit 0
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- pick an rsync ---------------------------------------------------------
# macOS ships openrsync, which lacks --backup-dir. Prefer a real GNU rsync
# (nix/homebrew) when present so overwritten files stay recoverable.
RSYNC=/usr/bin/rsync
BACKUP_ARGS=()
for cand in /run/current-system/sw/bin/rsync /opt/homebrew/bin/rsync; do
  if [[ -x "$cand" ]] && "$cand" --version 2>/dev/null | grep -q '^rsync  *version 3'; then
    RSYNC="$cand"
    BACKUP_ARGS=(--backup --backup-dir="$SRC/_private/mobile-sync-backups/$(date +%Y-%m-%d)")
    break
  fi
done

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
# Config is DESKTOP-AUTHORITATIVE and flows one way. Obsidian mobile writes a
# much sparser config than the desktop app (its app.json had only
# strictLineBreaks, and its daily-notes.json was missing the date format), and
# it rewrites those files on launch — so if config were allowed back through
# Leg B, mobile's stub would clobber the real settings. Excluding .obsidian/
# from Leg B entirely is what keeps daily-note paths, the attachment folder,
# and the template folder identical on both ends.
CONFIG_EXCLUDES_LEGB=(--exclude '/.obsidian/')

# Going out, everything in .obsidian/ is shared EXCEPT per-device UI state.
# workspace* covers the desktop's workspace.json AND the phone's separate
# workspace-mobile.json; because these are excluded (and --delete-excluded is
# never used) Leg A's --delete cannot destroy the phone's saved layout.
CONFIG_EXCLUDES_LEGA=(
  --exclude '/.obsidian/workspace*'    # per-device pane layout
  --exclude '/.obsidian/graph.json'    # per-device graph view state
)

DRY=(--dry-run)
[[ $APPLY -eq 1 ]] && DRY=()

MODE_DESC=$([[ $APPLY -eq 1 ]] && echo "APPLY" || echo "DRY RUN (nothing written)")
ARCH_DESC=$([[ $WITH_ARCHIVES -eq 1 ]] && echo "included" || echo "excluded")
log_info "🔄 obsidian mobile mirror — mode=$MODE_DESC archives=$ARCH_DESC"
log_debug "repo=$SRC"
log_debug "mirror=$DST"

if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$DST"
elif [[ ! -d "$DST" ]]; then
  log_info "mirror does not exist yet; dry run shows the initial seed"
  DST="${TMPDIR:-/tmp}/obsidian-mirror-empty"
  mkdir -p "$DST"
fi

# --- Leg B: iCloud -> repo (import mobile edits; never deletes) ------------
# Deletion arbitration. A file that exists in the mirror but not in the repo is
# ambiguous: it was either created on the phone, or deliberately deleted on the
# desktop. Plain rsync cannot tell the difference and would resurrect every
# desktop deletion forever. git settles it:
#   * git has never tracked the path  -> genuinely phone-created -> import it.
#   * git tracks the path but it is gone from disk -> a real deletion -> do NOT
#     re-import; let Leg A remove it from the mirror instead.
LEGB_PREVIEW=$("$RSYNC" -a --dry-run --itemize-changes --update \
  "${EXCLUDES[@]}" "${CONFIG_EXCLUDES_LEGB[@]}" "$DST/" "$SRC/" 2>/dev/null || true)

DELETION_EXCLUDES=()
while IFS= read -r relpath; do
  [[ -z "$relpath" ]] && continue
  [[ -e "$SRC/$relpath" ]] && continue          # already present: an edit, not a resurrection
  if git -C "$SRC" ls-files --error-unmatch -- "$relpath" >/dev/null 2>&1; then
    DELETION_EXCLUDES+=(--exclude "/$relpath")  # tracked + absent = deleted on purpose
    log_info "🗑️  honoring desktop deletion: $relpath"
  fi
done < <(printf '%s\n' "$LEGB_PREVIEW" | grep '^>f' | sed 's/^[^ ]* //')

LEGB=$("$RSYNC" -a "${DRY[@]}" --itemize-changes --update \
  ${BACKUP_ARGS[@]+"${BACKUP_ARGS[@]}"} \
  ${DELETION_EXCLUDES[@]+"${DELETION_EXCLUDES[@]}"} \
  "${EXCLUDES[@]}" "${CONFIG_EXCLUDES_LEGB[@]}" "$DST/" "$SRC/" 2>/dev/null || true)
IMPORTED=$(printf '%s\n' "$LEGB" | grep -c '^>f' || true)
if [[ "$IMPORTED" -gt 0 ]]; then
  log_info "⬅️  imported $IMPORTED file(s) from mobile into the repo:"
  printf '%s\n' "$LEGB" | grep '^>f' | sed -n '1,20p' | while read -r line; do
    log_info "     ${line#* }"
  done
  log_warn "mobile edits landed in the working tree — review and commit explicit paths"
else
  log_debug "no inbound changes from mobile"
fi

# --- Leg A: repo -> iCloud (publish; deletes orphans) ---------------------
LEGA=$("$RSYNC" -a "${DRY[@]}" --itemize-changes --delete \
  "${EXCLUDES[@]}" "${CONFIG_EXCLUDES_LEGA[@]}" "$SRC/" "$DST/" 2>/dev/null || true)
SENT=$(printf '%s\n'    "$LEGA" | grep -c '^>f' || true)
DELETED=$(printf '%s\n' "$LEGA" | grep -c '^\*deleting' || true)

[[ "$SENT" -gt 0 ]] && log_info "➡️  published $SENT file(s) to the mirror" \
                    || log_debug "mirror already up to date"

if [[ "$DELETED" -gt 0 ]]; then
  log_warn "🗑️  removed $DELETED file(s) from the mirror (deleted in repo):"
  printf '%s\n' "$LEGA" | grep '^\*deleting' | sed -n '1,20p' | while read -r line; do
    log_warn "     ${line#\*deleting }"
  done
fi

if [[ $APPLY -eq 0 ]]; then
  log_info "dry run complete — re-run with --apply to write"
fi
