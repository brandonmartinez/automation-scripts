# Project Context

- **Owner:** Brandon Martinez
- **Project:** automation-scripts — a personal macOS automation toolkit. Triggers orchestrated through Hazel (folder watch → wrapper → worker handoff). ~5,900 lines, almost entirely zsh with one Python helper.
- **Stack:** zsh (required), macOS + Homebrew, external CLIs (exiftool, ffmpeg, pdftotext, jq), OpenAI API. Lint via shellcheck, format via shfmt (`npm run lint` / `npm run format`).
- **Created:** 2026-07-06T16:26:54-04:00

## Role Focus

Shell / zsh Engineer. I write the core organizer logic and maintain `utilities/logging.sh`. Idiomatic, loud-failing zsh; `command`-prefixed utilities; logging via the shared library.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- `utilities/logging.sh` is the canonical logging layer: `setup_script_logging` routes output to `~/Library/Logs/automation-scripts/{module}/{script}.log`, supports rotation and leveled/colored output, and writes logs to stderr so function stdout stays clean.
- Conventions: `#!/usr/bin/env zsh`, `set -o errexit -o nounset -o pipefail`, `command`-prefix nix utilities, validate args + input files before acting, meaningful exit codes.
