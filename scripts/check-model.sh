#!/bin/sh
# Scribe only ever uses Claude Haiku 5.5. Fail the build if any other Claude model ID appears in the app's source.
root="${SRCROOT:-$(dirname "$0")/..}/Scribe"
others=$(grep -rnoE 'claude-[a-z]+-[0-9][a-z0-9-]*' "$root" --include='*.swift' | grep -v ':claude-haiku-5-5$')
if [ -n "$others" ]; then
  echo "$others" | while IFS= read -r line; do
    echo "${line%%:*}:$(echo "$line" | cut -d: -f2): error: Scribe only uses claude-haiku-5-5 for AI"
  done
  exit 1
fi
