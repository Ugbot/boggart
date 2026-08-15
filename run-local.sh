#!/usr/bin/env bash
# run-local.sh -- launch boggart against a LOCAL model.
#
#   ./run-local.sh pro    [boggart args...]   # deepseek-v4-pro   (larger DS4)
#   ./run-local.sh flash  [boggart args...]   # deepseek-v4-flash (smaller DS4)
#   ./run-local.sh oss    [boggart args...]   # gpt-oss-120b via llama.cpp
#   ./run-local.sh list                       # show the configured models
#
# Anything after the selector is passed straight to boggart, so:
#   ./run-local.sh pro --tui
#   ./run-local.sh pro "summarise this repo"
#   ./run-local.sh flash --resume
#
# boggart speaks the Anthropic Messages protocol; it POSTs to
# $ANTHROPIC_BASE_URL/v1/messages. The endpoint and model below are all it needs
# (ANTHROPIC_BASE_URL is env-wins, so it overrides whatever /auth has stored).
set -euo pipefail
cd "$(dirname "$0")"

# ---- local model catalogue --------------------------------------------------
# ds4-server (custom, Anthropic-compatible) already serves the DS4 models on
# :8000. gpt-oss is a GGUF served by llama.cpp's llama-server.
DS4_BASE="http://127.0.0.1:8000"
OSS_BASE="http://127.0.0.1:8080"
OSS_GGUF="$HOME/models/gpt-oss-120b-MXFP4.gguf"
LLAMA_SERVER="${LLAMA_SERVER:-/opt/homebrew/bin/llama-server}"

sel="${1:-pro}"; shift || true

case "$sel" in
  list)
    cat <<EOF
local models:
  pro    deepseek-v4-pro    $DS4_BASE   (ds4-server, larger DS4)   [running check below]
  flash  deepseek-v4-flash  $DS4_BASE   (ds4-server, smaller DS4)
  oss    gpt-oss            $OSS_BASE   (llama.cpp on $OSS_GGUF)
EOF
    curl -sf -m 1 "$DS4_BASE/v1/models" >/dev/null 2>&1 \
      && echo "ds4-server: UP on $DS4_BASE" || echo "ds4-server: DOWN"
    curl -sf -m 1 "$OSS_BASE/v1/models" >/dev/null 2>&1 \
      && echo "llama-server: UP on $OSS_BASE" || echo "llama-server: DOWN"
    exit 0 ;;

  pro|large|ds4) MODEL="deepseek-v4-pro";   BASE="$DS4_BASE" ;;
  flash|small)   MODEL="deepseek-v4-flash"; BASE="$DS4_BASE" ;;

  oss|gpt-oss|gptoss)
    MODEL="gpt-oss"; BASE="$OSS_BASE"
    # Bring llama-server up if it isn't already answering on :8080.
    if ! curl -sf -m 1 "$BASE/v1/models" >/dev/null 2>&1; then
      if [ ! -f "$OSS_GGUF" ]; then
        echo "gpt-oss GGUF not ready: $OSS_GGUF" >&2
        [ -f "$OSS_GGUF.part" ] && echo "(still downloading -- see ~/models/fetch-gptoss.sh)" >&2
        exit 1
      fi
      echo "starting llama-server for gpt-oss on $BASE ..." >&2
      "$LLAMA_SERVER" -m "$OSS_GGUF" --host 127.0.0.1 --port 8080 \
        --alias gpt-oss --ctx-size 32768 --jinja >/tmp/llama-gptoss.log 2>&1 &
      for _ in $(seq 1 60); do
        curl -sf -m 1 "$BASE/v1/models" >/dev/null 2>&1 && break; sleep 1
      done
    fi
    # NOTE: llama-server exposes the OpenAI API (/v1/chat/completions), not the
    # Anthropic /v1/messages boggart POSTs to. If boggart 404s here, front it with
    # an Anthropic<->OpenAI shim (or run gpt-oss under the same ds4-server that
    # serves the DS4 models). Flagged so this isn't a silent failure.
    ;;

  *) echo "unknown model '$sel' (try: pro | flash | oss | list)" >&2; exit 2 ;;
esac

# ---- health check, then launch ---------------------------------------------
if ! curl -sf -m 2 "$BASE/v1/models" >/dev/null 2>&1; then
  echo "no server answering on $BASE -- is it running?" >&2
  [ "$BASE" = "$DS4_BASE" ] && echo "(the DS4 models are served by ds4-server on :8000)" >&2
  exit 1
fi

# A key is required by the client but the local servers don't check it.
export ANTHROPIC_BASE_URL="$BASE"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-local}"
echo "boggart -> $MODEL @ $BASE" >&2
exec ./boggart --model "$MODEL" "$@"
