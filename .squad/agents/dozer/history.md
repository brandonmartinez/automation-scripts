# Project Context

- **Owner:** Brandon Martinez
- **Project:** automation-scripts — a personal macOS automation toolkit. Triggers orchestrated through Hazel (folder watch → wrapper → worker handoff). ~5,900 lines, almost entirely zsh with one Python helper.
- **Stack:** zsh (required), macOS + Homebrew, external CLIs (exiftool, ffmpeg, pdftotext, ImageMagick). Lint via shellcheck, format via shfmt.
- **Created:** 2026-07-06T16:26:54-04:00

## Role Focus

Media & File-Ops Engineer. I own `media/` and the data-safety mandate for any file-mutating script: idempotency, archive-before-destroy, dry-run/DEBUG modes, collision handling.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- macOS/BSD tool idioms in use: `stat -f%z`/`stat -f%B` for size/birthtime, `date -j -f` for date parsing, `exiftool -overwrite_original`, `ffmpeg` mpg→mp4 conversion with the original moved to `_archive/`.
- Existing pattern in `video-created-and-record-date-cleanup.sh`: honor a `DEBUG` env flag that logs the command it *would* run instead of executing — keep this dry-run convention for all destructive media scripts.
