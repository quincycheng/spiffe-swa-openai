#!/usr/bin/env bash
# Tear down everything this workshop creates, in reverse order.
# Safe to re-run. Leaves the OpenAI Workload Identity Provider alone (delete
# that in the console if you want a truly clean slate).
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

TD="${SWA_TRUST_DOMAIN:-swa-lab.local}"
SG=macos-lab
NG=macos-unix-ng
COMP=swa-server-macos-lab

# The control-plane deletions need a token. Acquire one if the caller has not.
if [ -z "${SWA_TOKEN:-}" ]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/swa-auth.sh" >/dev/null 2>&1 || true
fi
# Read after swa-auth.sh, which loads .env.
PREFIX_NG="${SWA_PREFIX_NODE_GROUP:-ai-prefix-test}"

echo "==> stopping the macOS agent"
pkill -f "swa-agent run" 2>/dev/null && echo "   agent stopped" || echo "   not running"
rm -f /tmp/swa-agent/public/api.sock /tmp/swa-agent-prefix/public/api.sock

echo "==> deleting the kind cluster"
KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name swa-lab 2>&1 | sed 's/^/   /'

echo "==> deleting the Secrets Manager login objects (docs/09), if any"
scripts/secrets-manager-authn.sh cleanup 2>&1 | grep -E '^(==>|HTTP)' | sed 's/^/   /'

echo "==> deleting SWA control-plane resources (innermost first)"
# Strict order: registered components and node groups are children of the server
# group, so they must go first, and the server group before the trust domain.
for p in \
  "/api/swa/trust-domains/${TD}/server-groups/${SG}/components/${COMP}" \
  "/api/swa/trust-domains/${TD}/server-groups/${SG}/node-groups/${NG}" \
  "/api/swa/trust-domains/${TD}/server-groups/${SG}/node-groups/${PREFIX_NG}" \
  "/api/swa/trust-domains/${TD}/server-groups/${SG}" \
  "/api/swa/trust-domains/${TD}" ; do
  printf '   DELETE %-72s -> ' "$p"
  scripts/swa-api.sh DELETE "$p" >/dev/null 2>&1 && echo "ok" || echo "failed/absent"
done

echo "==> confirming the trust domain is gone"
scripts/swa-api.sh GET "/api/swa/trust-domains" 2>/dev/null | jq -c '{count}' || true

echo "==> removing local key material"
rm -f artifacts/ca.key artifacts/ca.crt artifacts/ca.srl \
      artifacts/agent.key artifacts/agent.crt artifacts/agent.csr \
      agent-config/x509pop.key agent-config/x509pop.cert \
      artifacts/agent-prefix.key artifacts/agent-prefix.crt artifacts/agent-prefix.csr \
      agent-config-prefix/x509pop.key agent-config-prefix/x509pop.cert
echo "   done"

echo
echo "Teardown complete."
echo
echo "Not removed (delete by hand for a truly clean slate):"
echo "  * the OpenAI Workload Identity Provider and its service-account mapping,"
echo "    in the OpenAI console -- the IDs in .env refer to it"
echo "  * .env itself"
echo
echo "If any DELETE above reported failed/absent while the resource clearly"
echo "exists, re-run: children must be gone before a parent will delete."
