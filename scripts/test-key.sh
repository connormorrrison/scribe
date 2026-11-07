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
    # Empty requests ElevenLabs refuses without making audio (no credits), after checking the key's permissions.
    tts=$(curl -s -w '\n%{http_code}' -X POST https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb \
      -H "xi-api-key: $key" -H "content-type: application/json" -d '{"text":""}')
    stt=$(curl -s -w '\n%{http_code}' -X POST https://api.elevenlabs.io/v1/speech-to-text \
      -H "xi-api-key: $key" -F model_id=scribe_v1)
    fail=0
    for pair in "Text to Speech|$tts" "Speech to Text|$stt"; do
      name=${pair%%|*}; res=${pair#*|}
      code=$(echo "$res" | tail -n1); status=$(echo "$res" | sed '$d' | jq -r '.detail.status? // empty' 2>/dev/null)
      case "$status" in
        invalid_api_key) echo "ElevenLabs: key not recognised."; exit 1 ;;
        missing_permissions) echo "ElevenLabs $name: key works, but has No Access."; fail=1 ;;
        *) echo "ElevenLabs $name: OK (probe answered $code${status:+ $status})." ;;
      esac
    done
    exit $fail ;;
  *) echo "Usage: $0 anthropic|elevenlabs"; exit 1 ;;
esac
