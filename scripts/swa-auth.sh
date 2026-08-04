#!/usr/bin/env bash
# Authenticate to Secrets Manager - SaaS and export a SWA API access token.
#
# Two-step flow, per docs.cyberark.com "Authenticate user":
#   1. Identity platform: StartAuthentication -> AdvanceAuthentication  => ID token
#   2. Secrets Manager:   authn-oidc/cyberark/conjur/authenticate       => access token
#
# NOTE: IDSEC_SECRET is the Identity user's *password*, not an OAuth client
# secret. The client_credentials grant against /oauth2/platformtoken does NOT
# work for a plain Secrets Manager Admin user (returns access_denied).
#
# Usage:  source scripts/swa-auth.sh      # exports SWA_TOKEN, SWA_API_BASE
#
# IMPORTANT: this script is *sourced*, so it must not change shell options.
# `set -euo pipefail` here would leak errexit into the interactive shell, and the
# next command that returned nonzero -- e.g. swa-api.sh on an HTTP 409 -- would
# kill the terminal. All error handling below is therefore explicit.

# Fail the way the caller expects: return if sourced, exit if executed.
__swa_fail() { echo "$*" >&2; return 1 2>/dev/null || exit 1; }

# Locate the repo root: walk up from $PWD looking for .env. Works whether this
# script is sourced (bash or zsh) or executed, from any directory.
# Override explicitly with REPO_ROOT=/path if needed.
if [ -z "${REPO_ROOT:-}" ]; then
  REPO_ROOT="$PWD"
  while [ ! -f "${REPO_ROOT}/.env" ] && [ "${REPO_ROOT}" != "/" ]; do
    REPO_ROOT="$(dirname "${REPO_ROOT}")"
  done
fi
[ -f "${REPO_ROOT}/.env" ] || __swa_fail "cannot find .env (set REPO_ROOT=)" || return 1 2>/dev/null || exit 1

set -a; . "${REPO_ROOT}/.env"; set +a

for __v in IDSEC_USERNAME IDSEC_SECRET IDENTITY_TENANT_URL CONJUR_APPLIANCE_URL; do
  eval "__val=\${${__v}:-}"
  [ -n "${__val}" ] || { __swa_fail "${__v} is not set in ${REPO_ROOT}/.env"; return 1 2>/dev/null || exit 1; }
done
unset __v __val

# Resolve the real Identity tenant host. If IDENTITY_TENANT_URL points at the
# Secrets Manager host, /oauth2/platformtoken 302s to the correct *.id host.
__swa_resolve_identity_url() {
  case "${IDENTITY_TENANT_URL}" in
    *.id.cyberark.cloud*) printf '%s' "${IDENTITY_TENANT_URL%/}"; return 0 ;;
  esac
  curl -sS -o /dev/null -D - -X POST "${IDENTITY_TENANT_URL%/}/oauth2/platformtoken" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' 2>/dev/null \
    | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' \
    | sed -E 's#^(https://[^/]+).*#\1#'
}

IDENTITY_URL="$(__swa_resolve_identity_url)"
[ -n "${IDENTITY_URL}" ] || { __swa_fail "could not resolve Identity tenant URL"; return 1 2>/dev/null || exit 1; }

# --- Step 1: Identity ID token (username + password) ---
__SWA_START=$(curl -sS -X POST "${IDENTITY_URL}/Security/StartAuthentication" \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg u "${IDSEC_USERNAME}" '{Version:"1.0",User:$u}')")

if [ "$(printf '%s' "${__SWA_START}" | jq -r '.success' 2>/dev/null)" != "true" ]; then
  __swa_fail "StartAuthentication failed: $(printf '%s' "${__SWA_START}" | jq -r '.Message // .' 2>/dev/null)"
  return 1 2>/dev/null || exit 1
fi

TENANT_ID=$(printf '%s' "${__SWA_START}" | jq -r '.Result.TenantId')
__SWA_SESSION=$(printf '%s' "${__SWA_START}" | jq -r '.Result.SessionId')
# "UP" == username/password mechanism
__SWA_MECH=$(printf '%s' "${__SWA_START}" | jq -r '.Result.Challenges[0].Mechanisms[] | select(.Name=="UP") | .MechanismId')

if [ -z "${__SWA_MECH}" ] || [ "${__SWA_MECH}" = "null" ]; then
  __swa_fail "no UP (password) mechanism offered; available: $(printf '%s' "${__SWA_START}" | jq -rc '[.Result.Challenges[0].Mechanisms[].Name]')"
  return 1 2>/dev/null || exit 1
fi

__SWA_ADV=$(curl -sS -X POST "${IDENTITY_URL}/Security/AdvanceAuthentication" \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg t "${TENANT_ID}" --arg s "${__SWA_SESSION}" --arg m "${__SWA_MECH}" --arg a "${IDSEC_SECRET}" \
            '{TenantId:$t,SessionId:$s,MechanismId:$m,Action:"Answer",Answer:$a}')")

if [ "$(printf '%s' "${__SWA_ADV}" | jq -r '.Result.Summary' 2>/dev/null)" != "LoginSuccess" ]; then
  __swa_fail "AdvanceAuthentication failed: $(printf '%s' "${__SWA_ADV}" | jq -r '.Result.Summary // .Message // .' 2>/dev/null)"
  return 1 2>/dev/null || exit 1
fi

__SWA_ID_TOKEN=$(printf '%s' "${__SWA_ADV}" | jq -r '.Result.Token')

# --- Step 2: exchange the ID token for a Secrets Manager access token ---
# SWA_API_BASE is the tenant host WITHOUT the /api suffix.
SWA_API_BASE="$(printf '%s' "${CONJUR_APPLIANCE_URL%/}" | sed -E 's#/api/?$##')"

SWA_TOKEN=$(curl -sS -X POST "${SWA_API_BASE}/api/authn-oidc/cyberark/conjur/authenticate" \
  -H 'Accept-Encoding: base64' -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "id_token=${__SWA_ID_TOKEN}" | tr -d '\n\r')

if [ -z "${SWA_TOKEN}" ]; then
  __swa_fail "Secrets Manager authenticate returned empty token"
  return 1 2>/dev/null || exit 1
fi

export SWA_TOKEN SWA_API_BASE
echo "authenticated: tenant=${TENANT_ID} base=${SWA_API_BASE} token_len=${#SWA_TOKEN}"

# Do not leave working state (or the password-bearing responses) in the shell.
unset __SWA_START __SWA_ADV __SWA_SESSION __SWA_MECH __SWA_ID_TOKEN
