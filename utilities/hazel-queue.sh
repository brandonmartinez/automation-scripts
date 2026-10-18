#!/usr/bin/env zsh
set -o errexit -o nounset -o pipefail

readonly AUTOMATION_ROOT="${0:A:h:h}"
source "$AUTOMATION_ROOT/utilities/python-runtime.sh"
automation_python "$@"
