#!/bin/zsh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

# This Command Line Tools install intermittently fails to load the TestingMacros plugin
# ("plugin for module 'TestingMacros' not found"). It is unrelated to our code, so retry that specific failure.
for attempt in 1 2 3 4; do
  out=$(swift test "$@" 2>&1); code=$?
  if (( code != 0 )) && print -r -- "$out" | grep -q "plugin for module 'TestingMacros' not found"; then
    print -u2 "TestingMacros plugin flake (attempt $attempt), retrying…"
    continue
  fi
  print -r -- "$out"
  exit $code
done
print -r -- "$out"; exit 1
