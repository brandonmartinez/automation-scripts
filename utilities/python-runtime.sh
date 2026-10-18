#!/usr/bin/env zsh

set -o errexit -o nounset -o pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/run/current-system/sw/bin:${PATH:-/usr/bin:/bin}"

automation_python() {
    local candidate
    local -a candidates
    if [[ -n "${AUTOMATION_PYTHON:-}" ]]; then
        candidates=("$AUTOMATION_PYTHON")
    else
        candidates=(
            python3
            /opt/homebrew/bin/python3
            /usr/local/bin/python3
            /run/current-system/sw/bin/python3
            /nix/var/nix/profiles/default/bin/python3
            /usr/bin/python3
        )
    fi
    for candidate in "${candidates[@]}"; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
            export PYTHONDONTWRITEBYTECODE=1
            exec "$candidate" -I "$AUTOMATION_ROOT/utilities/hazel-python.py" "$@"
        fi
    done
    print -u2 -- "Python 3.11+ is required. Install it separately or set AUTOMATION_PYTHON to its absolute executable path (also in Hazel/launchd). No activation or download is performed."
    return 127
}
