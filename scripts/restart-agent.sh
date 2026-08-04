#!/usr/bin/env bash
# Restart the native macOS SWA agent from a clean slate.
#
# ALWAYS use this instead of retyping `swa-agent run`. Starting a second agent
# while one is running is the most common way to break the lab: the new process
# cannot bind the socket and exits, but it has already deleted the socket the
# healthy agent was serving and truncated its log. This script kills first, then
# starts exactly one agent, then verifies.
#
# A plain `kubectl rollout restart deploy/swa-server` does NOT require running
# this -- the published trust bundle accumulates roots, so a running agent
# reconnects and keeps its attestation. Run it after a bundle *reset*: the trust
# domain or server group being recreated, or a teardown-and-rebuild.
#
# See docs/04-macos-agent.md.
#
# This script is executed, not sourced, so changing shell options here is safe.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

AGENT="${AGENT:-swa-release-v1.0.2/binaries/swa-agent_1.0.0-SNAPSHOT_darwin_arm64/swa-agent}"
SOCKET_DIR="${SOCKET_DIR:-/tmp/swa-agent/public}"
LOG="${LOG:-/tmp/agent.log}"

[ -x "${AGENT}" ] || { echo "agent binary not found or not executable: ${AGENT}" >&2; exit 1; }

echo "==> stopping any running agent"
if pkill -f "swa-agent run" 2>/dev/null; then
  echo "   stopped"
else
  echo "   none running"
fi
sleep 2

echo "==> clearing the socket"
rm -f "${SOCKET_DIR}/api.sock"
mkdir -p "${SOCKET_DIR}"

# Truncating the log matters: otherwise the greps below count the previous run.
echo "==> starting agent (log: ${LOG})"
nohup "${AGENT}" run -d agent-config > "${LOG}" 2>&1 &
sleep 12

PID="$(pgrep -f 'swa-agent run' || true)"
# grep -c already prints 0 when there is no match and exits 1; a `|| echo 0`
# fallback here would append a second 0 and break the integer tests below.
ATTESTED="$(grep -ac 'attested=true'   "${LOG}" 2>/dev/null)"
ERRORS="$(grep -ac  'Failed to attest' "${LOG}" 2>/dev/null)"
ATTESTED="${ATTESTED:-0}"
ERRORS="${ERRORS:-0}"

echo
echo "   pid      : ${PID:-NOT RUNNING}"
echo "   attested : ${ATTESTED}"
echo "   errors   : ${ERRORS}"

if [ -z "${PID}" ]; then
  echo
  echo "FAILED: the agent is not running. Last lines:" >&2
  tail -5 "${LOG}" >&2
  exit 1
fi

if [ "${ERRORS}" -gt 0 ]; then
  echo
  echo "FAILED: attestation errors present:" >&2
  grep -a 'Failed to attest' "${LOG}" | tail -1 >&2
  echo >&2
  case "$(grep -a 'Failed to attest' "${LOG}" | tail -1)" in
    *"unknown authority"*)
      echo "hint: stale trust bundle. Is the swa-server pod Running? Check with" >&2
      echo "      kubectl get pods -n swa-system, then re-run this script." >&2 ;;
    *"digital signature"*)
      echo "hint: the x509pop cert lacks keyUsage=digitalSignature -- see docs/04." >&2 ;;
    *)
      echo "hint: see docs/07-troubleshooting.md" >&2 ;;
  esac
  exit 1
fi

if [ "${ATTESTED}" -eq 0 ]; then
  echo
  echo "FAILED: no attestation yet and no errors -- the agent may still be starting," >&2
  echo "or it was signalled to exit. See docs/07-troubleshooting.md" >&2
  exit 1
fi

ls -l "${SOCKET_DIR}/api.sock"
echo
echo "agent attested and serving. Next: scripts/fetch-svid.sh openai"
