#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

pkill -x Atrium || true
while pgrep -x Atrium >/dev/null; do sleep 0.1; done
./scripts/build.sh
open ~/Applications/Atrium.app --args "$@"     # e.g. ./scripts/run.sh --demo
