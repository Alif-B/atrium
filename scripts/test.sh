#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

swift test "$@"     # add --disable-xctest if swift test complains about XCTest
