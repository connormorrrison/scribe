#!/bin/sh
# Tests an API key copied to the clipboard, without it appearing in your shell history or terminal.
# Usage: copy a key, then run   scripts/test-key.sh anthropic   or   scripts/test-key.sh elevenlabs
key=$(pbpaste | tr -d '[:space:]')
[ -n "$key" ] || { echo "Clipboard is empty: copy the key first."; exit 1; }
case "$1" in
  anthropic)
    body=$(curl -s -w '\n%{http_code}' https://api.anthropic.com/v1/messages \
      -H "x-api-key: $key" -H "anthropic-version: 2026-10-21" -H "content-type: application/json" \
      -d '{"model":"claude-haiku-5-5","max_tokens":256,"output_config":{"effort":"low"},"messages":[{"role":"user","content":"Reply with the word OK."}]}')
    code=$(echo "$body" | tail -n1); json=$(echo "$body" | sed '$d')
    if [ "$code" = 200 ]; then
      echo "Anthropic: OK. Model $(echo "$json" | jq -r .model) replied: $(echo "$json" | jq -r '[.content[] | select(.type=="text") | .text] | join("")')"
    else
      echo "Anthropic: HTTP $code: $(echo "$json" | jq -r '.error.message // .')"; exit 1
    fi ;;
  elevenlabs)
    code=$(curl -s -o /dev/null -w '%{http_code}' https://api.elevenlabs.io/v1/models -H "xi-api-key: $key")
    [ "$code" = 200 ] && echo "ElevenLabs: OK." || { echo "ElevenLabs: HTTP $code"; exit 1; } ;;
  *) echo "Usage: $0 anthropic|elevenlabs"; exit 1 ;;
esac
