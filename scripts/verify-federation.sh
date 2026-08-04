#!/usr/bin/env bash
# Prove the federation is a real cryptographic gate, not a rubber stamp.
#
# Exchanges four subject tokens and shows only the legitimate one is accepted.
# This is the money slide for the workshop: run it live.
#
# Requires: OPENAI_IDENTITY_PROVIDER_ID, OPENAI_SERVICE_ACCOUNT_ID
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
: "${OPENAI_IDENTITY_PROVIDER_ID:?}" "${OPENAI_SERVICE_ACCOUNT_ID:?}"

exchange() {
  curl -sS -X POST "https://auth.openai.com/oauth/token" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg a "$1" \
             --arg p "$OPENAI_IDENTITY_PROVIDER_ID" \
             --arg s "$OPENAI_SERVICE_ACCOUNT_ID" \
             '{grant_type:"urn:ietf:params:oauth:grant-type:token-exchange",
               subject_token_type:"urn:ietf:params:oauth:token-type:jwt",
               subject_token:$a, identity_provider_id:$p, service_account_id:$s}')" \
    | jq -r 'if .access_token then "ACCEPTED"
             else "REJECTED: " + ((.error_description // .error.message // .error)|tostring) end'
}

GOOD="$("${REPO_ROOT}/scripts/fetch-svid.sh" openai)"

printf '%-42s' "1. valid SVID, correct audience"; exchange "${GOOD}"
printf '%-42s' "2. wrong audience"; exchange "$("${REPO_ROOT}/scripts/fetch-svid.sh" https://wrong.example.com)"
printf '%-42s' "3. tampered signature"; exchange "$(printf '%s' "${GOOD}" | awk -F. '{print $1"."$2".AAAA"substr($3,5)}')"
# Forged token: right claims, signed by a key that is not in the trust domain's JWKS.
FORGED_H=$(printf '%s' '{"alg":"RS512","kid":"fake-key","typ":"JWT"}' | base64 | tr -d '=\n' | tr '/+' '_-')
FORGED_P=$(printf '%s' '{"sub":"spiffe://swa-lab.local/macos-unix-ng/workload/qcheng","aud":["https://api.openai.com/v1"],"iss":"https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local","iat":1785830000,"exp":1900000000}' | base64 | tr -d '=\n' | tr '/+' '_-')
printf '%-42s' "4. forged token, key not in JWKS"; exchange "${FORGED_H}.${FORGED_P}.ZmFrZXNpZ25hdHVyZQ"

echo
echo "Only #1 should be ACCEPTED. Identity is enforced by signature + audience,"
echo "not by possession of a shared secret."
