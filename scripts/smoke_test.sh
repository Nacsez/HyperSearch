#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${HYPERSEARCH_BASE_URL:-http://127.0.0.1:8000}"
API_KEY="${HYPERSEARCH_API_KEY:-}"

headers=(-H "Content-Type: application/json")
if [[ -n "${API_KEY}" ]]; then
  headers+=(-H "X-API-Key: ${API_KEY}")
fi

echo "[smoke] health"
curl -fsS "${BASE_URL}/v1/health"
echo

echo "[smoke] search"
curl -fsS "${headers[@]}" \
  -X POST "${BASE_URL}/v1/search" \
  -d '{"query":"hypersearch smoke test","results_per_page":5,"max_pages":1,"page":1,"safe_search":1,"dedupe":true,"fetch_pages":false,"extract_text":false,"summarize":false,"streaming":false,"cache_policy":"bypass"}'
echo

echo "[smoke] research"
curl -fsS "${headers[@]}" \
  -X POST "${BASE_URL}/v1/research" \
  -d '{"query":"What is HyperSearch?","results_per_page":5,"max_pages":1,"page":1,"top_n":3,"streaming":false,"include_debug_trace":true,"cache_policy":"bypass"}'
echo

echo "[smoke] complete"

