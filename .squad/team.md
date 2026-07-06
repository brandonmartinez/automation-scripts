# Squad Team

> automation-scripts

## Coordinator

| Name | Role | Notes |
|------|------|-------|
| Squad | Coordinator | Routes work, enforces handoffs and reviewer gates. |

## Members

| Name | Role | Charter | Status |
|------|------|---------|--------|
| Morpheus | Lead / Automation Architect | .squad/agents/morpheus/charter.md | 🏗️ Active |
| Trinity | Shell / zsh Engineer | .squad/agents/trinity/charter.md | 🔧 Active |
| Tank | Event-Orchestration Engineer | .squad/agents/tank/charter.md | ⚙️ Active |
| Dozer | Media & File-Ops Engineer | .squad/agents/dozer/charter.md | 🎬 Active |
| Mouse | AI Integration Engineer | .squad/agents/mouse/charter.md | 🤖 Active |
| Scribe | Session Logger & Memory | .squad/agents/scribe/charter.md | 📋 Built-in |
| Ralph | Work Monitor | .squad/agents/ralph/charter.md | 🔄 Built-in |
| Rai | RAI Reviewer | .squad/agents/Rai/charter.md | 🛡️ Built-in |
| Fact Checker | Fact Checker | .squad/agents/fact-checker/charter.md | 🔍 Built-in |

## Project Context

- **Owner:** Brandon Martinez
- **Project:** automation-scripts — personal macOS automation toolkit. Triggers orchestrated through the Hazel app (folder watch → wrapper → worker handoff). ~5,900 lines, almost entirely zsh with one Python helper.
- **Stack:** zsh (required), macOS + Homebrew, Hazel, external CLIs (exiftool, ffmpeg, pdftotext, jq, op/1Password, Keychain), OpenAI API. Lint via shellcheck (`npm run lint`), format via shfmt (`npm run format`).
- **House rules:** `#!/usr/bin/env zsh`; `set -o errexit -o nounset -o pipefail`; `command`-prefix nix utilities; log via `utilities/logging.sh`; zsh-first (no new languages without owner approval); safe file ops (idempotent, archive-before-destroy).
- **Created:** 2026-07-06
