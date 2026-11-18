#!/usr/bin/env bash
# Usage: ./scripts/smoke_test.sh <SERVER_IP[:PORT]> [LLM_API_KEY] [MODEL_NAME]

set -euo pipefail

TARGET_HOST="${1:-127.0.0.1}"
API_KEY="${2:-sk-prod-gpu-llm-secret-token-2026}"
MODEL_NAME="${3:-qwen2.5:1.5b}"

if [[ "${TARGET_HOST}" != http://* && "${TARGET_HOST}" != https://* ]]; then
  BASE_URL="http://${TARGET_HOST}"
else
  BASE_URL="${TARGET_HOST}"
fi

echo "Target: ${BASE_URL} (model: ${MODEL_NAME})"

echo -e "\n[1/3] Checking GET ${BASE_URL}/health ..."
HEALTH_BODY_FILE="$(mktemp)"
HEALTH_CODE="$(curl -s -o "${HEALTH_BODY_FILE}" -w "%{http_code}" "${BASE_URL}/health")"
HEALTH_BODY="$(cat "${HEALTH_BODY_FILE}")"
rm -f "${HEALTH_BODY_FILE}"

echo "HTTP ${HEALTH_CODE}: ${HEALTH_BODY}"
if [[ "${HEALTH_CODE}" != "200" ]]; then
  echo "FAIL: Expected HTTP 200 from /health, got ${HEALTH_CODE}" >&2
  exit 1
fi

echo -e "\n[2/3] Checking unauthenticated request GET ${BASE_URL}/api/tags ..."
UNAUTH_BODY_FILE="$(mktemp)"
UNAUTH_CODE="$(curl -s -o "${UNAUTH_BODY_FILE}" -w "%{http_code}" "${BASE_URL}/api/tags")"
UNAUTH_BODY="$(cat "${UNAUTH_BODY_FILE}")"
rm -f "${UNAUTH_BODY_FILE}"

echo "HTTP ${UNAUTH_CODE}: ${UNAUTH_BODY}"
if [[ "${UNAUTH_CODE}" != "401" ]]; then
  echo "FAIL: Expected HTTP 401 without token, got ${UNAUTH_CODE}" >&2
  exit 1
fi

echo -e "\n[3/3] Checking authenticated inference POST ${BASE_URL}/v1/chat/completions ..."
INFER_BODY_FILE="$(mktemp)"
INFER_CODE="$(curl -s -o "${INFER_BODY_FILE}" -w "%{http_code}" \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Hello! Who are you in one short sentence?\"}
    ],
    \"max_tokens\": 64,
    \"temperature\": 0.0
  }")"
INFER_BODY="$(cat "${INFER_BODY_FILE}")"
rm -f "${INFER_BODY_FILE}"

echo "HTTP ${INFER_CODE}: ${INFER_BODY}"
if [[ "${INFER_CODE}" != "200" ]]; then
  echo "FAIL: Expected HTTP 200 from inference request, got ${INFER_CODE}" >&2
  exit 1
fi

echo -e "\nOK: All checks passed."
