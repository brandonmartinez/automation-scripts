# automation-scripts

A set of scripts used to automate tasks on my machines.

## Shell Requirements

All scripts in this project are written for **zsh** and should be executed with zsh. Each script includes the shebang `#!/usr/bin/env zsh` to ensure proper execution.

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
