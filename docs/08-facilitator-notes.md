# 08 — Facilitator notes

Everything you need to run this in a room, rather than at your own desk.

## Timings

Measured on an Apple Silicon Mac with a warm Podman machine.

| Step | Wall clock | Notes |
|---|---|---|
| Unpack + de-quarantine agent | ~30s | Faster if pre-staged |
| Tenant authentication | ~3s | |
| Create trust domain | ~2s | |
| Generate CA + agent certs | ~5s | `genrsa 4096` dominates |
| Create server group | ~2s | |
| **kind cluster create** | **26s** | Assumes the node image is already pulled |
| Load server image | ~10s | |
| Register server | ~2s | |
| **Helm install + pod ready** | **~20s** | |
| Create node group | ~2s | |
| Start agent + attest | ~5s | |
| Fetch + verify SVID | ~3s | |
| OpenAI console setup | **3–10 min** | The real variable. Manual, per-attendee |
| Token exchange + API call | ~4s | |

**Command-line total: under 3 minutes.** Everything else is console clicking and
first-time pulls.

First run on a cold machine adds substantially: `kindest/node:v1.35.5` is roughly
900 MB, and the Podman machine takes 20–40s to start.

## Pre-bake this

Anything that can fail on hotel wifi or a locked-down laptop should be done
before people arrive.

**Must pre-stage:**

1. **`kindest/node:v1.35.5` pulled.** Otherwise every attendee downloads ~900 MB
   simultaneously.
   ```bash
   podman pull kindest/node:v1.35.5
   ```
2. **De-quarantined agent binary.** Confirm `xattr` actually works on the target
   laptop:
   ```bash
   xattr -d com.apple.quarantine swa-agent && ./swa-agent version
   ```
   On a managed device with a strict Gatekeeper policy this can be impossible, and
   there is no workaround inside the lab. **Test on the actual hardware, not on
   yours.**
3. **`brew install kind helm kubectl jq`** and a running Podman machine.
4. **The `.env` file**, with tenant URL, username, password.
5. **OpenAI org owner access confirmed.** Members cannot see the Workload Identity
   Federation page at all. Verify by loading the page, not by checking a role
   label.
6. **Credits on the OpenAI project**, if you want a completion on screen rather
   than an HTTP 200 from `/v1/models`.

**Worth pre-baking for a short session:** the whole trust domain, server group,
kind cluster, and running server. That leaves attendees the interesting parts —
node group, agent, SVID, federation — in about 10 minutes.

## The six footguns that will bite attendees

### 1. The SPIFFE ID contains their Unix username

```
spiffe://swa-lab.local/macos-unix-ng/workload/<unix user>
```

So every attendee has a **different** SPIFFE ID, and the OpenAI mapping is
per-identity. Options:

- **One shared OpenAI org, individual mappings.** Realistic, but you must add
  each attendee's SPIFFE ID to the console live.
- **Standardise the username** by having everyone run the agent as the same user
  (a dedicated `swaworkshop` account). One mapping serves everyone. Simplest for a
  large room.
- **Each attendee uses their own OpenAI org.** Cleanest isolation, most setup, and
  each needs owner rights plus their own credits.

For more than about six people, standardise the username.

Have them print it early — before the console step, not during it:

```bash
scripts/fetch-svid.sh openai | cut -d. -f2 | \
  python3 -c 'import sys,base64,json;s=sys.stdin.read().strip();print(json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4)))["sub"])'
```

### 2. Node group ordering

Create the node group **after** the server is running, then expect the sync delay
([04](04-macos-agent.md#trap-no-generator-for-nodegroup)). If you pre-bake the
server, create node groups first and save everyone a `rollout restart`.

### 3. A closing terminal looks like a catastrophe

If anyone is running an older copy of `scripts/swa-auth.sh`, their terminal window
**closes** the first time an API call returns non-2xx — most likely an HTTP 409
from re-running the trust-domain `POST`. No error, just a vanished window, which
reads as something far worse than it is.

Cause and fix:
[07](07-troubleshooting.md#sourcing-a-script-closes-your-terminal). Screen for it
in one command before you begin:

```bash
source scripts/swa-auth.sh && set -o | grep errexit    # must say: off
```

Worth saying out loud early, because an attendee whose terminal disappears will
assume they broke something badly and stop following along.

### 4. Starting a second agent, which breaks the first one

This is the nastiest footgun in the workshop, and the one you should demonstrate
rather than describe. An attendee whose fetch fails will retype the `swa-agent run`
line. The second process cannot bind the socket and exits within a second — but on
its way in it has already **deleted the socket the healthy agent was serving**, and
its `>` has **truncated the log** containing the first agent's `attested=true`
lines. One keystroke turns a working lab into two dead agents plus a log that reads
exactly like rejected attestation:

```
attested=true      0
Failed to attest   0
```

Both counts zero is the signature. Attendees will read that as a certificate
problem and start regenerating `x509pop` certs, which are entirely innocent. Teach
the check and the fix as a pair:

```bash
pgrep -fl "swa-agent run" | wc -l    # must be 1
scripts/restart-agent.sh             # pkill, clear socket, start once, verify
```

Tell the room: **never type the agent start command twice — always use
`scripts/restart-agent.sh`.** Details in
[04](04-macos-agent.md#trap-the-log-looks-like-a-clean-shutdown).

### 5. Backgrounding the agent with a bare `&`

An agent started with `&` instead of `nohup ... &` dies with its terminal, and its
log ends in `Stopping`/`Stopped` with **no error and no `attested=true`** — the same
misleading signature as footgun 4, from a different cause. Combined with footgun 3,
a closing terminal takes the agent with it. The startup command in
[04](04-macos-agent.md#4-run-the-agent) uses `nohup`; make sure attendees copy it
rather than typing their own.

**What is *not* a footgun, despite appearances:** restarting `swa-server`. The pod
generates a new root CA on every start, but the published trust bundle accumulates
roots, so agents that outlive a restart keep working — verified across rolling
restarts, `scale 0`/`scale 1`, and a 90-second outage. You can safely
`rollout restart` the server centrally while attendees are mid-lab. Only a bundle
*reset* — recreating the trust domain or server group — orphans agents.

### 6. Gatekeeper

Covered above, but it bears repeating: it is the only failure in this workshop
that an attendee may be **unable** to fix. Screen for it in advance.

## Running the demo

A sequence that builds the argument rather than just executing steps.

**Open with the problem.** Show a real `.env` containing `OPENAI_API_KEY=sk-...`.
Ask: who has it, where else is it copied, when was it last rotated, and how would
you know if it leaked? That is secret zero.

**Show the identity, not the plumbing.** Fetch an SVID and decode it. It is a
300-second token, and no password was involved — authorisation came from *which
process called the socket*.

**Prove the trust is real, remotely.** Run the RS512 verification from
[05](05-fetch-svid.md) against CyberArk's public JWKS. Point out what is *not*
there: no tunnel, no ngrok, no inbound firewall rule. OpenAI fetches the same URL.

**Then federate.** `scripts/exchange-openai.sh`. HTTP 200 with no API key
anywhere.

**Close with the negative tests.** `scripts/verify-federation.sh` is the money
slide:

```
1. valid SVID, correct audience           ACCEPTED
2. wrong audience                         REJECTED: Invalid subject token.
3. tampered signature                     REJECTED: Invalid subject token.
4. forged token, key not in JWKS          REJECTED: Invalid subject token.
```

Dwell on test 4. That token carries the right `sub`, the right `aud`, the right
`iss`, an unexpired `exp`, **and** the correct `identity_provider_id` and
`service_account_id`. It fails only because SWA did not sign it. That is why
those IDs can sit in a `.env` and be projected on a wall.

**Then prove the point directly:**

```bash
grep -rE 'sk-(proj-)?[A-Za-z0-9]{20,}' docs/ scripts/ ; echo "exit: $?"
```

```
exit: 1
```

No API keys anywhere in the repository. That is the thesis.

## Questions you will be asked

**"Doesn't the agent certificate just become the new secret zero?"** Fair
challenge, and worth conceding partly. The x509pop certificate is a bootstrap
credential — but it attests a *node*, not an identity, it is issued per machine,
and in production you would use `k8s_psat`, a TPM, or a cloud instance-identity
document, none of which is a file you can copy. Compare the blast radius: a
leaked API key works from anywhere; a leaked node certificate still yields only
whatever the node group's policies permit.

**"What if the SWA control plane is down?"** SVID issuance stops, so new tokens
cannot be minted. Existing tokens work until expiry. This is a real availability
trade — the same one every OIDC federation makes.

**"Why not self-hosted SPIRE?"** You can, but its JWKS must be publicly
reachable for OpenAI to fetch it. On a laptop that means a tunnel, or manually
uploading keys and re-uploading on every rotation. The SaaS control plane is what
makes this work with no inbound network path.

**"Is 300 seconds not too short?"** The workload re-fetches on demand; the SDK
never sees a long-lived credential. Longer TTLs are configurable, but short ones
are the point.

**"Does this work with Bedrock / Vertex?"** Out of scope here. Bedrock uses
SigV4/IAM, not OIDC token exchange, so it is a different mechanism entirely — SWA
can supply an identity for it, but not by this path.

## Teardown

```bash
scripts/teardown.sh
```

Strictly innermost-first, because the control plane will not delete a parent
while children remain:

```
agent  ->  kind cluster  ->  registered component  ->  node group
       ->  server group   ->  trust domain          ->  local key material
```

Safe to re-run, and it acquires its own token if you have not sourced one.

**It deliberately leaves the OpenAI Workload Identity Provider alone.** Delete it
in the console if you want a truly clean slate. Keeping it saves the slowest
manual step on a re-run — the `sub` mapping stays valid as long as you recreate
with the *same* trust domain name, node group name, and Unix username, since the
SPIFFE ID is built from all three.

Verify nothing is left:

```bash
pgrep -fl swa-agent                                   # no output
KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters   # no swa-lab
source scripts/swa-auth.sh
scripts/swa-api.sh GET /api/swa/trust-domains | jq -c '{count}'
```

```
No kind clusters found.
{"count":0}
```

`pgrep` exiting 1 with no output is the success case. If `count` is not `0`, run
the script again — a `failed/absent` line on a resource that does exist means a
child had not yet been removed on the first pass.

To keep the kind cluster but stop paying for the Podman VM between sessions:

```bash
podman machine stop     # cluster survives; `podman machine start` and it comes back
```

## Adapting this beyond the lab

The workshop uses `unix` workload attestation and an empty
`workload_registration_policies`, which means *every* process on the attested node
gets an identity. For anything real:

- Add CEL policies to the node group, e.g. `unix.user == 'appuser'`, so only the
  intended workload receives an SVID.
- Use `k8s_psat` node attestation instead of `x509pop` where the workload runs in
  Kubernetes — no certificate file to distribute.
- Run the server outside `kind`, with a proper ingress rather than a NodePort.
- Shorten `controlPlane.syncInterval` from its 15-minute default if you register
  node groups dynamically.

---

Back to the [README](README.md).
