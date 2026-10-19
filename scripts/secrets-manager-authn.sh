#!/usr/bin/env bash
# Log in to CyberArk Secrets Manager with the prefixed SPIFFE JWT-SVID -- no API
# key, no password -- read a test secret, and show that other tokens are refused.
#
#   scripts/secrets-manager-authn.sh setup     # authenticator, host, grant, secret
#   scripts/secrets-manager-authn.sh test      # fetch SVIDs, authn-jwt, read secret
#   scripts/secrets-manager-authn.sh cleanup   # remove everything setup created
#
# The identity comes from .env: SWA_SPIFFE_PREFIX and SWA_PREFIX_NODE_GROUP (run
# scripts/spiffe-prefix.sh --restart first). setup creates only new objects:
#   authenticator  authn-jwt/swa-lab-spiffe-ai
#   policy branch  data/swa-lab-spiffe-ai   (host <prefix><user>, variable test-secret)
#   grant          that host -> group conjur/authn-jwt/swa-lab-spiffe-ai/apps
#
# On a shared tenant these are Secrets Manager writes: review before running.
# See docs/09-prefix-and-secrets-manager.md.
#
# This script is executed, not sourced, so changing shell options here is safe.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

# swa-auth.sh re-reads .env; values already exported by the caller win.
__prefix="${SWA_SPIFFE_PREFIX-}"; __ng="${SWA_PREFIX_NODE_GROUP-}"
# shellcheck source=/dev/null
. scripts/swa-auth.sh >/dev/null || exit 1
PREFIX="${__prefix:-${SWA_SPIFFE_PREFIX:-}}"
NG="${__ng:-${SWA_PREFIX_NODE_GROUP:-ai-prefix-test}}"
TD="${SWA_TRUST_DOMAIN:-swa-lab.local}"

SVC=swa-lab-spiffe-ai
BRANCH=data/${SVC}
HOST_NAME="$(printf '%s%s' "${PREFIX}" "$(id -un)" | tr '[:upper:]' '[:lower:]')"
HOST_ID=${BRANCH}/${HOST_NAME}
VAR_ID=${BRANCH}/test-secret
TD_URL="${SWA_API_BASE}/api/swa/trust-domains/${TD}"
AUD="${SWA_API_BASE}"
SUB="spiffe://${TD}/${NG}/workload/${PREFIX}$(id -un)"
PREFIX_SOCKET_DIR=/tmp/swa-agent-prefix/public
SCRATCH="$(mktemp -d -t sm-authn)"
trap 'rm -rf "${SCRATCH}"' EXIT

enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
conjur() {  # METHOD PATH [curl args...]
  local m="$1" p="$2"; shift 2
  curl -sS -X "$m" "${SWA_API_BASE}${p}" -H "Authorization: Token token=\"${SWA_TOKEN}\"" \
    -w '\nHTTP %{http_code}\n' "$@"
}
sub_of() { cut -d. -f2 | python3 -c 'import sys,base64,json;s=sys.stdin.read().strip();s+="="*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s))["sub"])'; }

setup() {
  echo "==> 1. authenticator authn-jwt/${SVC}"
  scripts/swa-api.sh POST /api/authenticators "$(jq -nc --arg n "$SVC" --arg td "$TD_URL" --arg aud "$AUD" \
    '{type:"jwt",name:$n,enabled:true,data:{jwks_uri:($td+"/.well-known/jwks"),issuer:$td,audience:$aud}}')"

  echo "==> 2. policy branch ${BRANCH}: host pinned to sub=${SUB}"
  # Re-running appends: a changed prefix adds a second host, the first remains
  # until cleanup.
  cat > "${SCRATCH}/data-policy.yml" <<YAML
- !policy
  id: ${SVC}
  body:
  - !host
    id: ${HOST_NAME}
    annotations:
      authn-jwt/${SVC}/sub: ${SUB}
  - !variable test-secret
  - !permit
    role: !host ${HOST_NAME}
    privileges: [ read, execute ]
    resource: !variable test-secret
YAML
  conjur POST /api/policies/conjur/policy/data -H 'Content-Type: application/x-yaml' \
    --data-binary @"${SCRATCH}/data-policy.yml"

  echo "==> 3. allow the host to use the authenticator"
  cat > "${SCRATCH}/grant-policy.yml" <<YAML
- !grant
  role: !group apps
  member: !host /${HOST_ID}
YAML
  conjur POST "/api/policies/conjur/policy/conjur/authn-jwt/${SVC}" -H 'Content-Type: application/x-yaml' \
    --data-binary @"${SCRATCH}/grant-policy.yml"

  echo "==> 4. test secret value"
  conjur POST "/api/secrets/conjur/variable/$(enc "$VAR_ID")" --data "hello from ${SUB}"
}

authn() {  # JWT -> response body, then the HTTP code on the last line
  # Conjur login names carry their kind: hosts authenticate as "host/<id>".
  # Without the prefix the request is a *user* login and fails with a bare 401.
  curl -sS -X POST "${SWA_API_BASE}/api/authn-jwt/${SVC}/conjur/$(enc "host/${HOST_ID}")/authenticate" \
    -H 'Content-Type: application/x-www-form-urlencoded' -H 'Accept-Encoding: base64' \
    --data-urlencode "jwt=$1" -w '\n%{http_code}'
}

test_() {
  echo "==> start the prefixed agent (${NG} node group) and fetch its SVID"
  CONFIG_DIR=agent-config-prefix SOCKET_DIR="${PREFIX_SOCKET_DIR}" LOG=/tmp/agent-prefix.log \
    scripts/restart-agent.sh >/dev/null 2>&1 || { echo "prefixed agent failed: see /tmp/agent-prefix.log" >&2; exit 1; }
  PREFIX_JWT="$(SWA_AGENT_SOCKET="${PREFIX_SOCKET_DIR}/api.sock" scripts/fetch-svid.sh "${AUD}")"
  GOT="$(printf '%s' "$PREFIX_JWT" | sub_of)"
  echo "   prefixed sub: ${GOT}"
  if [ "${GOT}" != "${SUB}" ]; then
    echo "   expected ${SUB} -- the server is still on an older template." >&2
    echo "   run: scripts/spiffe-prefix.sh --restart" >&2
  fi

  echo "==> restore the baseline agent and fetch its (non-prefixed) SVID"
  scripts/restart-agent.sh >/dev/null 2>&1
  BASE_JWT="$(scripts/fetch-svid.sh "${AUD}")"
  echo "   baseline sub: $(printf '%s' "$BASE_JWT" | sub_of)"

  echo
  echo "==> A. authn-jwt with the prefixed SVID  (expect 200)"
  R="$(authn "$PREFIX_JWT")"; CODE="${R##*$'\n'}"; TOK="${R%$'\n'*}"
  echo "   HTTP ${CODE}"
  if [ "$CODE" = 200 ]; then
    echo "   access token acquired ($(printf '%s' "$TOK" | wc -c | tr -d ' ') chars)"
    echo "==> read ${VAR_ID} with that token"
    curl -sS "${SWA_API_BASE}/api/secrets/conjur/variable/$(enc "$VAR_ID")" \
      -H "Authorization: Token token=\"${TOK}\"" -w '\n   HTTP %{http_code}\n'
  else
    echo "   body: ${TOK}"
  fi

  echo
  echo "==> B. authn-jwt with the baseline SVID for the same host  (expect 401)"
  R="$(authn "$BASE_JWT")"; echo "   HTTP ${R##*$'\n'}"
  echo "==> C. tampered prefixed SVID  (expect 401)"
  R="$(authn "$(printf '%s' "$PREFIX_JWT" | awk -F. '{print $1"."$2".AAAA"substr($3,5)}')")"; echo "   HTTP ${R##*$'\n'}"
}

cleanup() {
  echo "==> delete policy branch ${BRANCH} (hosts, variable, permit)"
  printf -- '- !delete\n  record: !policy %s\n' "$SVC" > "${SCRATCH}/delete-policy.yml"
  conjur PATCH /api/policies/conjur/policy/data -H 'Content-Type: application/x-yaml' \
    --data-binary @"${SCRATCH}/delete-policy.yml"
  echo "==> delete authenticator ${SVC}"
  scripts/swa-api.sh DELETE "/api/authenticators/${SVC}"
}

case "${1:-}" in
  setup) setup ;;
  test) test_ ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 setup|test|cleanup" >&2; exit 2 ;;
esac
