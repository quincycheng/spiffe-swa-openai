#!/usr/bin/env bash
# Apply SWA_SPIFFE_PREFIX (from .env) to the SPIFFE ID template of the node group
# SWA_PREFIX_NODE_GROUP, creating the node group if it does not exist yet.
#
#   scripts/spiffe-prefix.sh            # create or update the node group
#   scripts/spiffe-prefix.sh --restart  # ...then restart swa-server so it is used
#
# Resulting identity:
#   spiffe://<SWA_TRUST_DOMAIN>/<SWA_PREFIX_NODE_GROUP>/workload/<SWA_SPIFFE_PREFIX><unix user>
#
# The server caches node-group configuration (15-minute sync), so a new or
# changed template is not used until swa-server restarts. A running agent
# survives that restart. See docs/09-prefix-and-secrets-manager.md.
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
SG=macos-lab

# The server rejects these too (HTTP 422), but its message names the rendered
# SPIFFE ID rather than the variable you need to fix.
if ! printf '%s' "${PREFIX}" | grep -Eq '^[A-Za-z0-9._-]*$'; then
  echo "SWA_SPIFFE_PREFIX='${PREFIX}' is invalid: use letters, digits, '.', '-', '_' only" >&2
  exit 1
fi

# Only the part after {{ .nodegroup }}/ may be customised; the server enforces it.
TEMPLATE="spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/${PREFIX}{{ .unix.user }}"
NG_PATH="/api/swa/trust-domains/${TD}/server-groups/${SG}/node-groups"

CURRENT="$(scripts/swa-api.sh GET "${NG_PATH}/${NG}" 2>/dev/null | jq -r '.workload_configuration.spiffe_id_template // empty')"
if [ "${CURRENT}" = "${TEMPLATE}" ]; then
  echo "==> node group ${NG} already uses this template -- nothing to change"
elif [ -n "${CURRENT}" ]; then
  echo "==> updating node group ${NG}"
  BODY="$(jq -nc --arg t "${TEMPLATE}" '{workload_configuration:{spiffe_id_template:$t}}')"
  OUT="$(scripts/swa-api.sh PATCH "${NG_PATH}/${NG}" "${BODY}")" || { echo "${OUT}" >&2; exit 1; }
else
  echo "==> creating node group ${NG}"
  BODY="$(jq -nc --arg n "${NG}" --arg t "${TEMPLATE}" \
    '{name:$n, description:"prefixed SPIFFE IDs (docs/09)", workload_type:"unix",
      workload_configuration:{spiffe_id_template:$t}}')"
  OUT="$(scripts/swa-api.sh POST "${NG_PATH}" "${BODY}")" || { echo "${OUT}" >&2; exit 1; }
fi

STORED="$(scripts/swa-api.sh GET "${NG_PATH}/${NG}" 2>/dev/null | jq -r '.workload_configuration.spiffe_id_template')"
echo "   stored template : ${STORED}"
if [ "${STORED}" != "${TEMPLATE}" ]; then
  echo "FAILED: stored template differs from the one sent" >&2
  exit 1
fi
echo "   your SPIFFE ID  : spiffe://${TD}/${NG}/workload/${PREFIX}$(id -un)"

# --restart applies even when nothing changed above: an earlier run may have
# saved the template without restarting.
if [ "${1:-}" = "--restart" ]; then
  echo "==> restarting swa-server so it loads the template"
  kubectl rollout restart deploy/swa-server -n swa-system >/dev/null || exit 1
  kubectl rollout status deploy/swa-server -n swa-system --timeout=120s | tail -1
elif [ "${CURRENT}" != "${TEMPLATE}" ]; then
  echo
  echo "Not in effect yet: restart the server, or re-run with --restart:"
  echo "  kubectl rollout restart deploy/swa-server -n swa-system"
fi
