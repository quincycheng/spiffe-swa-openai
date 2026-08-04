#!/usr/bin/env bash
# Thin wrapper for SWA API calls. Source swa-auth.sh first (or let this do it).
#
# Usage:
#   scripts/swa-api.sh GET  /api/swa/trust-domains
#   scripts/swa-api.sh POST /api/swa/trust-domains '<json body>'
#
# Prints "HTTP <code>" to stderr and the response body to stdout.
# Exits 0 on 2xx, 1 otherwise -- so `cmd || echo failed` works, but note this
# script must be EXECUTED, never sourced (a nonzero exit would close your shell).
set -uo pipefail   # deliberately NOT -e: we handle curl failure explicitly

METHOD="${1:?usage: swa-api.sh METHOD PATH [BODY_JSON]}"
PATH_="${2:?usage: swa-api.sh METHOD PATH [BODY_JSON]}"
BODY="${3:-}"

if [ -z "${SWA_TOKEN:-}" ]; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "$0")" && pwd)/swa-auth.sh" >/dev/null || exit 1
fi

set -- -sS -X "${METHOD}" "${SWA_API_BASE}${PATH_}" \
  -H "Authorization: Token token=\"${SWA_TOKEN}\"" \
  -H "Accept: application/x.secretsmgr.v2+json"

if [ -n "${BODY}" ]; then
  set -- "$@" -H "Content-Type: application/json" -d "${BODY}"
fi

TMP="$(mktemp -t swa-api)"
trap 'rm -f "${TMP}" "${TMP}.body"' EXIT

CODE="$(curl "$@" -w '%{http_code}' -o "${TMP}.body" 2>"${TMP}")"
if [ -z "${CODE}" ]; then
  echo "curl failed: $(tr -d '\n' < "${TMP}")" >&2
  exit 1
fi

echo "HTTP ${CODE}" >&2
[ -s "${TMP}.body" ] && { cat "${TMP}.body"; echo; }

case "${CODE}" in
  2*) exit 0 ;;
  401) echo "hint: token expired or wrong scheme -- re-run: source scripts/swa-auth.sh" >&2; exit 1 ;;
  406) echo "hint: missing/incorrect Accept header (expected application/x.secretsmgr.v2+json)" >&2; exit 1 ;;
  409) echo "hint: resource already exists -- this is idempotent-safe, continue" >&2; exit 1 ;;
  *)  exit 1 ;;
esac
