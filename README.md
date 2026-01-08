# automation-scripts

A set of scripts used to automate tasks on my machines.

## Shell Requirements

All scripts in this project are written for **zsh** and should be executed with zsh. Each script includes the shebang `#!/usr/bin/env zsh` to ensure proper execution.

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
		- Optional key name override for 1Password item:
			```sh
			security add-generic-password -a "$USER" -s "op-key-name-openai-api" -w "<VAULT/ITEM>" -U
			```
		- Direct API key fallback (used if `op` fails):
			```sh
			security add-generic-password -a "$USER" -s "openai-api-key" -w "<OPENAI_API_KEY>" -U
			```
		Replace placeholders with your values.

### Development Environment

This project includes configuration files to ensure consistent development:

- **EditorConfig** (`.editorconfig`): Defines coding standards including shell variant as zsh
- **VS Code Settings** (`.vscode/settings.json`): Configures ShellCheck and shell formatting for zsh
- **VS Code Extensions** (`.vscode/extensions.json`): Recommends helpful extensions for shell script development

### Tools

For best development experience, install:

- **ShellCheck**: `brew install shellcheck` - Linting for shell scripts
- **shfmt**: `brew install shfmt` - Formatting for shell scripts

Both tools are configured to work with zsh syntax in the VS Code settings.
