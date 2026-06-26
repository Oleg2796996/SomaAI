#!/bin/bash
# Benchmark Wormsoft model aliases — picks the fastest one for our use case.
# Reads API key from WS_KEY environment variable (NEVER hardcode it).
#
# Usage:
#   export WS_KEY="sk-..."
#   bash scripts/bench.sh
#
# Outputs: table of model alias | HTTP code | response time | first 80 chars

set -e

if [ -z "$WS_KEY" ]; then
  echo "ERROR: WS_KEY environment variable not set."
  echo "Run: export WS_KEY='sk-...your-key...'"
  echo "Then: bash scripts/bench.sh"
  exit 1
fi

echo "=== Wormsoft Model Benchmark ==="
echo "Endpoint: ai.wormsoft.ru/api/gpt/v1/chat/completions"
echo "Payload: {\"hi\"} max_tokens=5"
echo ""

# Models to test. These are the system aliases and direct model names
# from the Wormsoft LK (https://ai.wormsoft.ru/lk/system-aliases).
MODELS=(
  "wormsoft/agent/low"
  "wormsoft/agent/medium"
  "wormsoft/agent/high"
  "wormsoft/code/low"
  "wormsoft/code/medium"
  "wormsoft/code/high"
  "wormsoft/vision/low"
  "wormsoft/vision/medium"
  "wormsoft/vision/high"
  "qwen/qwen3-vl"
  "qwen/qwen3.6:35b-a3b"
  "qwen/qwen3.6:27b"
  "google/gemma4:31b"
  "minimaxai/minimax-m2.7"
  "minimaxai/minimax-m3"
  "kimi/kimi-k2.6"
  "kimi/kimi-k2.7-code"
  "zai/glm-5.1"
  "deepseek-ai/deepseek-v3.1"
)

# Warm up the connection first.
echo "[warmup] ..."
curl -s -o /dev/null -m 30 -X POST "https://ai.wormsoft.ru/api/gpt/v1/chat/completions" \
  -H "Authorization: Bearer $WS_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"wormsoft/code/medium\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" > /dev/null

printf "%-32s %-8s %-10s %s\n" "MODEL" "HTTP" "TIME(s)" "RESPONSE"
printf "%-32s %-8s %-10s %s\n" "--------------------------------" "----" "--------" "--------"

for MODEL in "${MODELS[@]}"; do
  RESP=$(curl -s -m 30 -X POST "https://ai.wormsoft.ru/api/gpt/v1/chat/completions" \
    -H "Authorization: Bearer $WS_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
    -w "HTTP:%{http_code}|TIME:%{time_total}")
  HTTP=$(echo "$RESP" | grep -o "HTTP:[0-9]*" | cut -d: -f2)
  TIME=$(echo "$RESP" | grep -o "TIME:[0-9.]*" | cut -d: -f2)
  BODY=$(echo "$RESP" | head -1 | head -c 80)
  printf "%-32s %-8s %-10s %s\n" "$MODEL" "$HTTP" "$TIME" "$BODY"
done

echo ""
echo "=== Done. Pick the fastest 200-OK model. ==="