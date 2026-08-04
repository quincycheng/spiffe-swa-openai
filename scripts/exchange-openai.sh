#!/usr/bin/env bash
# Exchange a SPIFFE JWT-SVID for a short-lived OpenAI access token, then make a
# real API call. No OPENAI_API_KEY is ever set or read.
#
# Required (from the OpenAI console, Organization -> Security -> Workload
# Identity Provider; these are IDs, not secrets). The live console issues:
#   OPENAI_IDENTITY_PROVIDER_ID   idp_...
#   OPENAI_SERVICE_ACCOUNT_ID     user-...
# Read from .env if not already exported.
#
# This script is executed, not sourced, so changing shell options here is safe.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Self-sufficient: don't require the caller to have exported .env first.
if [ -z "${OPENAI_IDENTITY_PROVIDER_ID:-}" ] || [ -z "${OPENAI_SERVICE_ACCOUNT_ID:-}" ]; then
  [ -f "${REPO_ROOT}/.env" ] && { set -a; . "${REPO_ROOT}/.env"; set +a; }
fi

: "${OPENAI_IDENTITY_PROVIDER_ID:?set OPENAI_IDENTITY_PROVIDER_ID in .env (from the OpenAI console)}"
: "${OPENAI_SERVICE_ACCOUNT_ID:?set OPENAI_SERVICE_ACCOUNT_ID in .env (from the OpenAI console)}"

JWT="$("${REPO_ROOT}/scripts/fetch-svid.sh" openai)"
echo "JWT-SVID sub: $(printf '%s' "$JWT" | cut -d. -f2 | python3 -c 'import sys,base64,json;s=sys.stdin.read().strip();print(json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4)))["sub"])')"

RESP=$(curl -sS -X POST "https://auth.openai.com/oauth/token" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
        --arg a "$JWT" \
        --arg p "$OPENAI_IDENTITY_PROVIDER_ID" \
        --arg s "$OPENAI_SERVICE_ACCOUNT_ID" \
        '{grant_type:"urn:ietf:params:oauth:grant-type:token-exchange",
          subject_token_type:"urn:ietf:params:oauth:token-type:jwt",
          subject_token:$a,
          identity_provider_id:$p,
          service_account_id:$s}')")

if ! ACCESS_TOKEN=$(printf '%s' "$RESP" | jq -er '.access_token'); then
  echo "token exchange FAILED:" >&2
  printf '%s\n' "$RESP" | jq . >&2 || printf '%s\n' "$RESP" >&2
  exit 1
fi
echo "exchange OK: access_token acquired (${#ACCESS_TOKEN} chars, short-lived)"

# Saved so the docs' inspection snippets can read it. It expires in ~5 minutes.
umask 077
printf '%s' "$ACCESS_TOKEN" > /tmp/openai-access-token.txt
echo "saved to /tmp/openai-access-token.txt (expires in ~5 min)"

echo "--- live API call ---"
curl -sS https://api.openai.com/v1/responses \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.6-terra","input":"Reply with exactly: SPIFFE federation works."}' \
  | jq -r '.output[]?.content[]?.text // .error.message // .'
