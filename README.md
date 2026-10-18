# automation-scripts

A set of scripts used to automate tasks on my machines.

## Shell Requirements

Project `.sh` entry points use **zsh** (`#!/usr/bin/env zsh`). The Hazel-connected paperwork/PDF, guitar-tab, and video AI workflows now delegate to **Python 3.11+**, using the standard-library-only `automation_lib` package. Their existing shell paths remain executable compatibility wrappers. See [Hazel Python workflows](docs/hazel-python.md) for runtime requirements, usage, queue transition, recovery, and rollback.

Other automation remains zsh. The third-party `media/photo-multicrop2.sh` script and the Squad template `.squad/templates/skills/distributed-mesh/sync-mesh.sh` use **Bash**. Always follow each file's shebang.

## Environment Variables

- `OPENAI_API_KEY` **required** for the OpenAI helper scripts (e.g., `ai/open-ai-functions.sh`).
	- If set in your environment, it will be used directly.
	- If not set, the scripts try 1Password via `op read op://<key-name>/credential` where `<key-name>` defaults to `cli/openai-api` (or `OP_KEY_NAME` if set). If `op` is missing or fails, they fall back to macOS Keychain entry `openai-api-key`.
	- The `op` path can also use a service token from Keychain: store it under `op-service-token-openai-api` so `OP_SERVICE_ACCOUNT_TOKEN` can be loaded at runtime.
	- To store values in Keychain:
		- Service token (for 1Password CLI):
			```sh
			security add-generic-password -a "$USER" -s "op-service-token-openai-api" -w "<SERVICE_TOKEN>" -U
			```
		- Set `OP_KEY_NAME="<VAULT/ITEM>"` in the caller's environment to override the 1Password item. The helpers do not read a Keychain item for this override.
		- Direct API key fallback (used if `op` fails):
			```sh
			security add-generic-password -a "$USER" -s "openai-api-key" -w "<OPENAI_API_KEY>" -U
			```
		Replace placeholders with your values.

### Development Environment

This project includes configuration files to ensure consistent development:

- **EditorConfig** (`.editorconfig`): Defines four-space shell indentation and excludes zsh from shfmt directory discovery, with explicit Bash exceptions
- **VS Code Settings** (`.vscode/settings.json`): Separates zsh files from supported shell formatting and linting, without machine-specific executable paths
- **VS Code Extensions** (`.vscode/extensions.json`): Recommends helpful extensions for shell script development

### Tools

Install the recommended **zshcheck** extension (`justfatlard.zshcheck`) for its separate `zsh` language mode and syntax highlighting. This workspace uses its language support only: the extension's checker is disabled to avoid adding background processes. The workspace associates `.sh` and `.zsh` files with `zsh` by default, except for the two Bash files listed above, which use `shellscript`. Zsh formatting is manual: automatic formatting is disabled, and Shell Format and ShellCheck are not registered for `zsh`. Neither shfmt nor ShellCheck supports a zsh dialect; do not relabel zsh files as Bash to use them.

For supported Bash/POSIX/mksh/Bats syntax, **Shell Format** (`foxundermoon.shell-format`) uses its extension-managed shfmt backend and EditorConfig settings. A separate shfmt installation is not required for VS Code; the extension may need network access to download its platform-specific backend on first use. **ShellCheck** (`timonwong.shellcheck`) is optional for supported shell dialects, using its normal executable discovery rather than a repository-pinned Homebrew path.

Use `npm run lint` for parse-only checks of project `.sh` files with their native zsh or Bash interpreter; it does not execute the automation scripts. For a single zsh file, use `zsh -f -n path/to/script.sh`. The Bash Squad template can be checked separately with `bash -n .squad/templates/skills/distributed-mesh/sync-mesh.sh`.

Use `npm run test:hazel` (Python 3.11+ on `PATH`) for offline `unittest` coverage of the migrated workflows and their queues. It uses disposable homes and fake AI/OCR/media/credential tools; it never calls live inference. The legacy comparison tests materialize only the approved baseline's scripts into those disposable trees using local Git objects. No dependencies are downloaded. `npm run test:3d` remains the existing, separate 3D regression suite.

`npm run format` formats only the project Bash file, `media/photo-multicrop2.sh`, and requires a standalone `shfmt` on `PATH`. For a read-only formatter parse check, use `shfmt media/photo-multicrop2.sh >/dev/null`. Provision optional CLI tools through your existing package-management setup; do not add machine-specific paths to the workspace configuration.

When adding a supported non-zsh `.sh` file, add matching exceptions to `.vscode/settings.json` and `.editorconfig`, and deliberately update the formatting command if it should be included. EditorConfig's `ignore` protects shfmt directory discovery, but Shell Format 7.2.5 does not honor it; the separate VS Code language modes provide the editor-side protection. Direct shfmt invocations must still target only supported files.
