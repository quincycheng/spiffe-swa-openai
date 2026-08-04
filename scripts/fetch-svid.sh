#!/usr/bin/env bash
# Fetch a JWT-SVID from the local SWA Agent Workload API and print it.
#
#   scripts/fetch-svid.sh openai      -> audience https://api.openai.com/v1
#   scripts/fetch-svid.sh <audience>  -> literal audience
#
# Nothing here reads an API key. The only input is the process's own Unix
# identity, which the agent attests over the Workload API socket.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT="${REPO_ROOT}/swa-release-v1.0.2/binaries/swa-agent_1.0.0-SNAPSHOT_darwin_arm64/swa-agent"
SOCKET="${SWA_AGENT_SOCKET:-/tmp/swa-agent/public/api.sock}"

case "${1:-openai}" in
  openai)    AUD="https://api.openai.com/v1" ;;
  *)         AUD="$1" ;;
esac

[ -S "${SOCKET}" ] || { echo "no Workload API socket at ${SOCKET} — is the agent running?" >&2; exit 1; }

"${AGENT}" api fetch jwt -a "${AUD}" -s "${SOCKET}" --output json \
  | jq -r '.[0].svids[0].svid'
