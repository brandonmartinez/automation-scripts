# Project Context

- **Owner:** Brandon Martinez
- **Project:** automation-scripts — a personal macOS automation toolkit. Triggers orchestrated through Hazel (folder watch → wrapper → worker handoff). ~5,900 lines, almost entirely zsh with one Python helper. AI presence is small today but a growth area.
- **Stack:** zsh (required), macOS + Homebrew, OpenAI API, `op`/1Password + macOS Keychain for secrets, `jq`, `pdftotext`. Lint via shellcheck, format via shfmt.
- **Created:** 2026-07-06T16:26:54-04:00

## Role Focus

AI Integration Engineer. I own `ai/open-ai-functions.sh`, the AI-classification pieces of the organizers, secret resolution, and the sole Python helper. Secrets never leak; responses parsed defensively.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- `OPENAI_API_KEY` resolution chain: env var → `op read op://${OP_KEY_NAME:-cli/openai-api}/credential` (service token pulled from Keychain `op-service-token-openai-api`) → macOS Keychain `openai-api-key`. `OPENAI_MODEL` defaults to `gpt-5.1`, base URL overridable via `OPENAI_API_BASE_URL`.
- `get-openai-response` retries up to 3× with exponential backoff and `--max-time 60`, masks the `Authorization` header, and extracts `.choices[0].message.content` with control-char cleaning + multiple fallbacks. Keep this resilience when extending.
- Owner rule: zsh-first — no new Python/Node/Ruby without explicit approval. `organize-guitar-tabs-format.py` is the one approved helper.
