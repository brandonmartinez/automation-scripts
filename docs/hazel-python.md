# Hazel Python workflows

## Scope and runtime

The PDF/paperwork, guitar-tab, and video AI imports use `automation_lib/`, a small
Python **3.11+** standard-library package. There is no pip dependency, daemon,
plugin framework, activation, or automatic installation. Keep the checkout intact:
the wrappers need `utilities/`, `automation_lib/`, and the existing
`organization/organize-guitar-tabs-format.py` formatter.

Existing `hazel/hazel-organize-*-wrapper.sh`, `*-worker.sh`,
`organization/organize-{pdf-with-openai,guitar-tabs,video-imports}.sh`, and
`media/pdf-ocr-text.sh` paths remain executable zsh entry points. Arguments are
passed as argv, never shell command strings. Workers now use the organizer in
**their own checkout**, not a hard-coded `$HOME/src/automation-scripts` checkout.
Nothing here changes installed Hazel rules or launchd jobs.

`utilities/python-runtime.sh` tries `python3` on PATH, then known Homebrew, Nix,
and system locations, accepting only 3.11+. Set `AUTOMATION_PYTHON` to an absolute
executable path to pin it; an invalid explicit pin fails rather than selecting a
different interpreter. Discovery works without login profiles. Shell wrappers
add Homebrew/Nix binary directories to the inherited PATH; independently installed
specialist tools still need to be available there. Python is launched with `-I`
to avoid ambient Python startup/module overrides. No tool is installed for you.

| Workflow | Specialist tools | Preserved defaults |
|---|---|---|
| Paperwork | `pdftotext`; `ocrmypdf` only for empty text; `curl` or Copilot CLI; `osascript`; `open` when revealing | OpenAI `gpt-5.4`, optional `AI_PROVIDER=copilot` with `COPILOT_MODEL=gpt-5.4` |
| Guitar | `curl` | OpenAI `gpt-5.1`, two formatting/validation passes, existing deterministic OnSong formatter |
| Video | `ffprobe`, `ffmpeg`, `curl`; optional `open` | Vision `gpt-4o`, summary `gpt-4.1`, audio `whisper-1`; 30-second interval, 100-frame cap, WebP |

The video help's old 10-second/50-frame descriptions were incorrect; the actual
30/100 defaults are preserved. `--max-frames 0` remains unlimited. Invalid
intervals/dimensions/quality now fail clearly instead of entering shell arithmetic
or codec failures. Unused `FRAME_SIM_THRESHOLD` still has no effect.

OpenAI requests retain their original prompts, schemas, model overrides,
`OPENAI_API_BASE_URL`, model-dependent temperature handling, schema downgrade,
and reasoning-effort behavior. The mechanically extracted prose/schema is in
`automation_lib/prompts.json`. Only paperwork dispatches `AI_PROVIDER`; guitar and
video still use OpenAI directly. Copilot paperwork calls retain the existing
headless flags, private working directory, two attempts, schema prompt, and
configured MCP-server disable flags.

Credentials resolve at inference time: `OPENAI_API_KEY`, then
`op read op://<OP_KEY_NAME-or-cli/openai-api>/credential` (optionally loading
`OP_SERVICE_ACCOUNT_TOKEN` from Keychain service `op-service-token-openai-api`),
then Keychain service `openai-api-key` for the current user. `OP_KEY_NAME` is an
environment override, not a Keychain item. No `.env` file is read. The direct
OpenAI guitar/video paths require OpenAI credentials even if `AI_PROVIDER` was
accidentally set to `copilot`; paperwork Copilot calls do not require them.

## Usage and output contracts

```sh
organization/organize-pdf-with-openai.sh --move --state-file /path/to/plan.json /path/to/scan.pdf
organization/organize-pdf-with-openai.sh --dry-run --state-file /path/to/plan.json /path/to/scan.pdf
organization/organize-guitar-tabs.sh --debug /path/to/raw.txt
organization/organize-video-imports.sh --interval 30 --max-frames 100 /path/to/video.mov
```

These commands perform real work when used outside the tests. Activation and
real-tool smoke tests require a separate decision; they are not part of migration
verification.

### Installed Hazel invocation audit

A read-only inspection of the installed Hazel 6.1.2 configuration found five
active rules using external executable scripts, with no extra arguments or
embedded shell overrides. Their paths are rooted at
`$HOME/src/automation-scripts/`, not this development worktree. Hazel supplies the
current full file path as the sole argument and uses the executable's shebang.

| Watched folder | Script relative to checkout | Relevant action order |
|---|---|---|
| `~/Documents/Scans/OCR` | `media/pdf-ocr-text.sh` | OCR synchronously, then move original to `Scans/AI` |
| `~/Documents/Scans/AI` | `hazel/hazel-organize-pdf-with-openai-wrapper.sh` | Copy/enqueue, then move original to `Scans/Done` |
| `~/Documents/Guitar Tabs/_import` | `hazel/hazel-organize-guitar-tabs-wrapper.sh` | Copy/enqueue, then move original to `_trash` |
| `~/Documents/Sort/Videos/Import` | `hazel/hazel-organize-video-imports-wrapper.sh` | Move to sibling `Done`, then enqueue the moved path |
| `/Volumes/Videos/Import/Organize/Import` | `hazel/hazel-organize-video-imports-wrapper.sh` | Move to sibling `Done`, then enqueue the moved path |

These paths, arguments, and action orders need no rule edits for the migration.
Direct executable tests reproduce them in disposable trees, including moving
PDF/guitar originals before workers read their retained payloads. The two video
locations are simulated on local temporary storage, not the real mounted volume.
All required specialist executables were discoverable using the wrappers' PATH
additions over `/usr/bin:/bin`; this does not exercise authentication, macOS
permissions, real external tools, or network-volume filesystem behavior.

Hazel automatically retries nonzero shell actions. An accepted submission is
therefore recorded transactionally until its worker launch is acknowledged.
If the wrapper fails or is interrupted during that handoff, another invocation
with the same path and file version reuses the job instead of creating a
duplicate; a changed input gets a separate job. Completed handoffs and explicit
`HAZEL_NO_WORKER=1` enqueues remain separate submissions. This is not a general
exactly-once guarantee after Hazel itself crashes following a successful action.

Paperwork retains `PAPERWORK_DIR`, `REVEAL_IN_FINDER`, sender aliases, taxonomy
reuse, confidence review lane, `NEEDS_REVIEW_DIRNAME`, filename date hints,
descriptions, Finder comments, copy/move options, and `pdf-agentic-v1` JSON fields.
The standalone backfill still calls the same shell engine with
`--dry-run --state-file` and `ORIGINAL_FILE_PATH`; `.plan.final`, `.plan.analysis`,
`.plan.confidence`, and `.action.proposedPath` remain compatible. The standalone
renderer is unchanged. Phase timestamps/log presentation are normalized; state
still contains the discovery/analysis/action phases and notes arrays.

Guitar output is still `ARTIST - SONG.txt`; debug output is beside its input as
`ARTIST - SONG-debug.txt`, preserving the input. Non-debug processing removes only
the working input after full publication. The existing formatter, tuning/flow
logic, chart newline behavior, raw response debug file, and validation pass are
retained. Doubly encoded JSON and literal newlines in JSON strings are decoded;
unparseable/truncated output now fails instead of guessing chart content from a
regular expression.

Video output is still `<video stem>.md`, with the same Markdown bytes, description
fields, and plain-text audio transcript formatting. Video files are never moved.
Work remains under `<video directory>/_temp/<stem>/`: `frames/`, `scenes.jsonl`,
and `audio/{audio.ogg,audio_transcript.txt}`. The plain-text model response's
legacy JSON quoting in scene descriptions/timeline prompts is deliberately
preserved, not silently reformatted. Scene caches can read the legacy pretty
JSON-object stream as well as compact JSONL. New writes use compact JSONL.

## Intentional process improvements

- Queues are transactional SQLite jobs, not append/truncate lists. Concurrent
  enqueue, claims, worker exit, and crashes cannot clear another enqueue.
- PDF/guitar input copies have unique per-job directories, avoiding same-basename
  overwrites. Source paths, including spaces, Unicode, metacharacters, and
  newlines, are stored as data. Video jobs continue to reference the source.
- Publication uses private temporary files, fsync, and atomic no-clobber links.
  PDF/guitar collisions get `-001`, `-002`, etc.; charts no longer overwrite an
  existing output. UTF-8 **bytes**, including collision suffixes, are bounded to
  255 per filename. Modes and mtime are copied. Same-filesystem PDF moves use a
  hard link followed by source unlink, preserving inode/birthtime; cross-device
  copies cannot promise original macOS birthtime/resource-fork preservation.
- Paperwork dry-run no longer creates taxonomy/archive directories or mutates
  the source with OCR. OCR operates on a private copy; real filing publishes that
  OCR result, not the unprocessed original. Source removal follows metadata and
  durable action recording. Failure retains source and partial output/plan.
- A detected input replacement/change during inference prevents publication and
  removal. Symlinked input, state, cache, queue, and output boundaries are refused
  rather than followed. macOS system `/var`, `/tmp`, `/etc` aliases are allowed.
  These checks assume a trusted local filesystem, not hostile concurrent
  directory replacement.
- Workers share kernel-owned `flock` leases, not age/PID heuristics. A lease is
  inherited by the active organizer, so killing the worker cannot let recovery
  race an organizer still running. Ordinary signals terminate/reap only directly
  owned children. No PID discovered in an old lock is ever signalled.
- Each enqueue kicks a detached, stdio-independent worker. Workers wait for the
  family lease and recheck jobs, closing the enqueue/worker-exit lost-wakeup
  window without a daemon. The process is pinned to the wrapper's checkout.
- Failures, missing files, malformed input/jobs, and interrupted runs are
  retained and visible. Retry is explicit; failed jobs do not spin or disappear.
  Worker exit is nonzero if that drain failed or recovered interrupted jobs.
- Video caches have source identity/options and a status manifest, preventing
  accidental cross-source/cache reuse. Description checkpoints are atomic;
  retries reuse completed frames and the **actual** audio transcript location
  (fixing the old root-vs-audio cache mismatch). Probe, frame, or transcription
  failures do not become a success-shaped visual-only summary. Complete,
  existing summaries are not rewritten and do not trigger additional inference.
- Logging retains the existing per-workflow macOS log locations with bounded
  rotation serialized across processes; shell color/`bat` presentation and
  environment/command-line dumps were removed. Logs never print
  credential-bearing subprocess argv.

## Queue paths and ownership

For `FAMILY` equal to `pdf-with-openai`, `guitar-tabs`, or `video-imports`, let
`BASE=$HOME/.hazel-organize-FAMILY-queue`:

| Path | Purpose |
|---|---|
| `BASE.sqlite3` | Durable jobs, imported-batch ledger, and unacknowledged wrapper submissions |
| `BASE.jobs/<id>/` | Retained job artifacts; paperwork `plan.json`, output `publication.json` receipt |
| `BASE.python-worker.lock` | Permanent kernel lease file; **do not unlink** it |
| `BASE.python-import.lock` | Permanent serialization file for legacy imports; **do not unlink** it |
| `BASE.python-enqueue.lock` | Permanent serialization file for wrapper acceptance/launch handoff; **do not unlink** it |
| `BASE.legacy-<id>` | Preserved legacy queue snapshot, imported once transactionally |
| `BASE.processing.*` | Interrupted legacy video batches, imported once and retained |

PDF/guitar payloads live under
`~/Documents/{Scans,Guitar Tabs}/_temp/<job id>/<original name>`. Empty job/staging
directories and done rows are deliberately retained; there is no automatic
retention policy deleting user artifacts. State/receipts/databases are private
files. Copies preserve the input file's mode, so they remain as private or public
as the source. Protect the containing home/archive and backups accordingly.

## Transition (not automatic deployment)

1. Pause the affected Hazel rules, including both video locations and the
   standalone OCR stage, and stop/drain **old** workers. Do not run old and Python
   workers concurrently. Back up the legacy queue files, `.processing.*` batches,
   and referenced `_temp` payloads.
2. Inspect any legacy `BASE.lock` / `BASE.oplock` directory. The new runtime
   refuses to run while either exists, even if old or its PID is dead. After
   verifying no old worker owns it, remove only that specific legacy lock by
   hand. The code never recursively removes or guesses ownership of old locks.
3. Make the complete new checkout available at the paths Hazel already uses.
   Check the interpreter/tool configuration in that execution environment.
4. Import each stopped legacy queue without running inference:

   ```sh
   utilities/hazel-queue.sh import-legacy pdf-with-openai
   utilities/hazel-queue.sh import-legacy guitar-tabs
   utilities/hazel-queue.sh import-legacy video-imports
   utilities/hazel-queue.sh status pdf-with-openai
   ```

   Workers also perform this import before draining. The nonempty queue file is
   atomically renamed to `BASE.legacy-<id>` and retained. Snapshot records and
   their ledger entry commit together; retry after a crash does not double-import.
   Existing `.processing.*` files are not deleted. Duplicate lines remain
   separate jobs; missing files fail visibly instead of being silently skipped.
   Legacy paths must be absolute UTF-8. Relative paths have no recoverable
   original cwd and are marked failed; invalid UTF-8 batches remain unimported
   with an explicit error until manually repaired.
5. Before a video with no existing summary uses old `_temp/<stem>` data, inspect
   and manually archive that specific cache directory. It has no verifiable
   source/options manifest, so the Python workflow refuses to trust or delete it.
   Leave its data available for recovery; a fresh run will create a new cache.
6. Inspect imported jobs, then separately approve real-tool smoke tests and
   resume the rules. No production queue, watched folder, app setting, or launchd
   job is modified by the offline tests.

An accepted new job is no longer appended to `BASE`; that path is only a legacy
import boundary. Do not point the old worker at the new database. Job publication
failure is nonzero and retains source/staging for inspection. A worker launch
failure is nonzero **after acceptance**, with the job still pending. Hazel's
retry of the unchanged input reuses that job and tries the launch again; a manual
worker drain is also possible. No error is hidden as a successful handoff.
Wrappers now print `Queued job <id>` on acceptance instead of remaining silent,
making the durable job easy to find in status output.

## Recovery and inspection

```sh
utilities/hazel-queue.sh status guitar-tabs
utilities/hazel-queue.sh retry guitar-tabs <failed-job-id>
hazel/hazel-organize-guitar-tabs-worker.sh
```

Status is JSON. `pending -> running -> done` is the normal transition.
`running -> failed` records errors/signals; after a hard crash the next worker
marks interrupted running jobs failed, **never silently retries them**.
`retry` changes only one failed row back to pending; it does not run inference.
`HAZEL_NO_WORKER=1` suppresses automatic worker startup for controlled enqueue
operations (tests use it).

Inspect the worker log, payload, paperwork plan/video manifest, and actual
destination before retrying. If `publication.json` exists, retry refuses until
the partial completion has been reconciled and that specific receipt has been
archived manually. A receipt records the output path/hash, not a general
exactly-once guarantee. A crash between output publication and its receipt is
still an ambiguous boundary; inspect outputs even if no receipt exists.
No source/job is discarded to hide that ambiguity. A new worker can remain
blocked after a hard kill while the inherited lease's organizer finishes; do
not unlink its lease or signal an unverified process.

Logs are in `~/Library/Logs/hazel-organize-FAMILY-{wrapper,worker}.log` and
`~/Library/Logs/automation-scripts/organization/organize-FAMILY.log`.
The standalone OCR helper retains
`~/Library/Logs/automation-scripts/media/pdf-ocr-text.log`.
Paperwork with an explicit `--state-file` atomically replaces that plan even on
failure, adding `metadata.error` while keeping `action.completed=false`.
Without a state path, it records a private temporary plan and logs the path,
as before. Logs/plans may contain private document content; treat them as such.

## Rollback

Pause the rules, wait for/stop verified Python workers and organizers, and back up
the SQLite databases plus all job/payload/cache artifacts. Keep the entire
database, including failed and interrupted rows; do not delete it as rollback.
Restore the previous code deployment only after stopping the Python workers.

The old code cannot read SQLite. Use `status FAMILY` **before replacing the
Python checkout** to inspect pending/failed rows. Manually select only work still
requiring processing, verify its `payload` exists, and reconstruct the stopped
legacy line queue from those absolute payload paths. Inspect all partial outputs
first; never replay done rows or blindly restore a whole `.legacy-*` snapshot
that may contain already-completed jobs. New payload names containing newline
characters cannot be represented by the old format; handle those individually
instead of exporting corrupt lines. Retain the database and archived queues so
the selection is auditable. The old queue's overwrite/error-loss limitations
return with the old code.

Existing PDF plans and final outputs remain usable by the unchanged backfill
and renderer. Video `workflow.json` is additional cache metadata; old code ignores
it. Keep fresh and archived video caches separate when switching versions to
avoid the old code reusing incompatible frame settings.

## Offline verification

`npm run test:hazel` uses `unittest`, owned disposable HOME/TMP/cache/output trees,
guarded fake executables, and the local approved baseline
`d84f07f0e500489e926f846da2657c89ea37c2a7` for differential checks. The fake
PATH explicitly excludes real AI, credentials, OCR, codecs, and application
launches. Legacy test copies remove their hard-coded Homebrew PATH prepends.
Tests compare actual requests, argv, chart/Markdown bytes, scene data, paperwork
plans, paths, mode/mtime, failures, collisions, concurrency, and interruptions.
The production baseline must be available in local Git history for those tests.

Offline runtime verification used Python 3.14.8; this is not proof of Python
3.11 runtime compatibility. The suite additionally checks 3.11 grammar, but
minimum-version runtime and real-tool integration still require separately
available runtimes/approval.
