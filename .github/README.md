# Automation Scripts

This repository contains shell automation scripts written for **zsh**.

## Shell Environment
- **Shell**: zsh (required)
- **Compatibility**: macOS with Homebrew
- **Path**: Scripts expect `/opt/homebrew/bin` and `/usr/local/bin` in PATH

## Project Structure
```
automation-scripts/
├── ai/                 # AI-related automation scripts
├── media/              # Media processing scripts
├── organization/       # File organization scripts
├── utilities/          # Shared utility functions
│   └── logging.sh     # Common logging functions
└── README.md
```

## Development
Project automation scripts use zsh syntax and should be executed with zsh. Preserve the Bash shebangs in `media/photo-multicrop2.sh` and the Squad `sync-mesh.sh` template. The project includes:
- EditorConfig for consistent formatting
- VS Code `zsh` mode via the recommended `justfatlard.zshcheck` extension's language support, with its background checker disabled and zsh formatting kept manual
- ShellCheck and shfmt integration for supported shell dialects only

Run `npm run lint` for native, parse-only project shell checks. See the root [README](../README.md#tools) for formatter prerequisites and the explicit Bash file exceptions.

## Usage
Scripts follow a consistent pattern:
- Comprehensive argument validation
- Structured logging with emoji indicators
- Proper error handling and exit codes
- Environment variable configuration
