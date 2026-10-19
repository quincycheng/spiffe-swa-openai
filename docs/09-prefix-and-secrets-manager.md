# 09 — Prefixed SPIFFE IDs, and logging in to Secrets Manager with one

Two extensions to the core workshop, each verified against the same tenant:

1. **A configurable prefix on the workload's SPIFFE ID**, set in `.env`:

   ```
   spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
                                                  ^^^^^^
   ```

2. **Using that identity to authenticate to CyberArk Secrets Manager itself** —
   the same secret-zero argument as [06](06-openai-federation.md), but now the
   relying party is the secrets manager. The workload reads a secret with no API
   key, no password, and no host credential of any kind.

Everything here runs on a **separate node group** (`ai-prefix-test`), so
`macos-unix-ng` and the OpenAI mapping from 06 keep working untouched.

Prerequisite: the lab from [03](03-swa-server-kind.md) and
[04](04-macos-agent.md) is running.

## 1. Configure the prefix

Two variables in `.env` (both are in `.env-template`):

```bash
SWA_SPIFFE_PREFIX=AI000-
SWA_PREFIX_NODE_GROUP=ai-prefix-test
```

The prefix is prepended to the Unix username in the last segment of the SPIFFE
ID. Letters, digits, `.`, `-` and `_` only — SPIFFE path-segment rules. Upper
case is fine (only the trust domain must be lower case). An empty prefix means
the SWA default.

## 2. What the template allows

The node group's `spiffe_id_template` is the mechanism. The default, which 04
leaves in place, is:

```
spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/{{ .unix.user }}
```

It is a Go template, and literal text may sit next to a variable — so the prefix
is simply `.../workload/AI000-{{ .unix.user }}`. The field is optional on node
group `POST` and `PATCH` (`PUT` returns 405). The SWA API docs don't spell this
out; the Terraform provider shipped in the release does, under
`terraform-provider/*/docs/resources/node_group.md`.

**Only the part after the node group is yours.** The server validates the
template at save time and rejects three classes of mistake:

```
spiffe://{{ .trustdomain }}/workload/{{ .unix.user }}
HTTP 422  node_group_invalid_spiffe_template_variable
          spiffe_id_template must begin with "spiffe://{{ .trustdomain }}/{{ .nodegroup }}/"

spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/{{ .unix.user
HTTP 422  spiffe_id_template produces an invalid SPIFFE ID when rendered: path segment
          characters are limited to letters, numbers, dots, dashes, and underscores

spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/{{ .unix.bogus }}
HTTP 422  node_group_invalid_spiffe_template_variable
          unknown workload attestor selector variable: "unix.bogus"
```

So a prefix can never move in front of the node group segment, and a typo fails
immediately rather than at SVID issuance.

## 3. Apply it

```bash
scripts/spiffe-prefix.sh --restart
```

```
==> updating node group ai-prefix-test
HTTP 200
   stored template : spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/AI000-{{ .unix.user }}
   your SPIFFE ID  : spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
==> restarting swa-server so it loads the template
deployment "swa-server" successfully rolled out
```

The script creates the node group if it does not exist (`POST`), otherwise
updates it (`PATCH`), then reads the template back and fails if it differs from
what was sent.

### Trap: the template is saved, but SVIDs don't change

**`--restart` is not optional.** The server caches node-group configuration and
re-syncs every 15 minutes (`controlPlane.syncInterval`), so a saved template is
not used until the next sync or a restart. Observed while changing `AI000-` to
`AI001-`:

```
immediately after PATCH (no restart): spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
after rollout restart:                spiffe://swa-lab.local/ai-prefix-test/workload/AI001-qcheng
```

A running agent survives the restart — 0 attestation errors, as in
[03](03-swa-server-kind.md#7-confirm-the-server-joined-the-control-plane). A
*new* node group has the same delay; that is the
[`no generator for nodegroup`](04-macos-agent.md#trap-no-generator-for-nodegroup)
error from 04.

## 4. An agent for the prefixed node group

The agent certificate's CN decides which node group a node joins, so the
prefixed node group needs its own certificate — signed by the same CA, with the
same `digitalSignature` extension as in [04](04-macos-agent.md#2-generate-the-agent-certificate):

```bash
set -a; source .env; set +a
openssl genrsa -out artifacts/agent-prefix.key 2048
openssl req -new -key artifacts/agent-prefix.key -out artifacts/agent-prefix.csr \
  -subj "/CN=${SWA_PREFIX_NODE_GROUP}"
openssl x509 -req -days 365 -in artifacts/agent-prefix.csr \
  -CA artifacts/ca.crt -CAkey artifacts/ca.key -CAserial artifacts/ca.srl \
  -extfile artifacts/x509pop-ext.cnf -out artifacts/agent-prefix.crt

cp artifacts/agent-prefix.crt agent-config-prefix/x509pop.cert
cp artifacts/agent-prefix.key agent-config-prefix/x509pop.key
chmod 600 agent-config-prefix/x509pop.key
openssl x509 -in agent-config-prefix/x509pop.cert -noout -subject
```

```
subject=CN=ai-prefix-test
```

`agent-config-prefix/config.yaml` is committed; it is `agent-config/config.yaml`
with a different socket (`/tmp/swa-agent-prefix/public/api.sock`). The key and
certificate are gitignored.

Start it with the same script as the baseline agent, pointed at the other
directory:

```bash
CONFIG_DIR=agent-config-prefix SOCKET_DIR=/tmp/swa-agent-prefix/public \
  LOG=/tmp/agent-prefix.log scripts/restart-agent.sh
```

```
==> stopping any running agent
   stopped
==> clearing the socket
==> starting agent (log: /tmp/agent-prefix.log)

   pid      : 44239
   attested : 5
   errors   : 0
srw-rw-rw-@ 1 qcheng  wheel  0 19 Oct 13:39 /tmp/swa-agent-prefix/public/api.sock
```

**This stops the baseline agent.** `restart-agent.sh` kills every `swa-agent
run` first, deliberately (see [04](04-macos-agent.md#4-run-the-agent)), so the
two agents take turns. Plain `scripts/restart-agent.sh` brings the baseline back.

```bash
SWA_AGENT_SOCKET=/tmp/swa-agent-prefix/public/api.sock scripts/fetch-svid.sh openai
```

Decoded claims:

```json
{
  "aud": ["https://api.openai.com/v1"],
  "iss": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local",
  "sub": "spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng"
}
```

The X.509-SVID carries the same ID as its URI SAN.

### Trap: `certificate has expired or is not yet valid` on a brand-new certificate

```
level=ERROR msg="Failed to attest" ... PermissionDenied desc = certificate verification
failed: x509: certificate has expired or is not yet valid: current time
2026-10-19T05:37:56Z is before 2026-10-19T05:38:34Z
```

The certificate was signed seconds earlier on the Mac, so its `notBefore` is
"now" — but the Podman VM's clock was **52 seconds behind**, so to the server the
certificate did not exist yet. The VM's chrony could see the offset but had
marked every source unusable (`x` / `~` in `chronyc sources`) and was not
correcting it, typically after the Mac sleeps. Check and fix:

```bash
echo "node - mac: $(( $(podman exec swa-lab-control-plane date -u +%s) - $(date -u +%s) ))s"
podman machine ssh 'sudo chronyc -a makestep'
```

```
node - mac: -51s        # before
node - mac: 1s          # after makestep
```

Then re-run `restart-agent.sh`. Waiting out the offset also works; the same
drift breaks token exchanges later (see
[07](07-troubleshooting.md#clock-skew)).

## 5. The prefix and OpenAI

The OpenAI mapping from 06 matches `sub` exactly, so a prefixed SVID is refused
until the mapping is changed. (Captured while the template was `AI001-`, during
the restart test above.)

```bash
SWA_AGENT_SOCKET=/tmp/swa-agent-prefix/public/api.sock scripts/exchange-openai.sh
```

```
JWT-SVID sub: spiffe://swa-lab.local/ai-prefix-test/workload/AI001-qcheng
token exchange FAILED:
{
  "error": {
    "message": "The provided service_account_id mapping does not match token attributes.",
    "type": "invalid_request_error",
    "param": null,
    "code": "invalid_grant"
  }
}
```

That message is *different* from the `Invalid subject token.` that forged and
tampered tokens get in 06: the signature was accepted, and only the subject
mapping failed. To use the prefixed identity with OpenAI, add a mapping for its
`sub` in the console.

## 6. Log in to Secrets Manager with the SPIFFE identity

Secrets Manager's `authn-jwt` authenticator can trust the trust domain's public
JWKS directly — the same public endpoint OpenAI uses. Nothing new is exposed.

The chain: the agent attests the Unix user → the SWA Server issues a 5-minute
JWT-SVID with the prefixed `sub` → Secrets Manager verifies it against the JWKS,
issuer, audience, and a pinned `sub` → returns a session for a host that can read
one secret.

### Setup

```bash
scripts/secrets-manager-authn.sh setup
```

It creates, all under one name so they are easy to find and remove:

| Object | Purpose |
|---|---|
| authenticator `authn-jwt/swa-lab-spiffe-ai` | `jwks_uri` = the trust domain's `.well-known/jwks`; `issuer` = `TD_URL`; `audience` = the tenant URL |
| policy branch `data/swa-lab-spiffe-ai` | host `ai000-qcheng`, annotated `authn-jwt/swa-lab-spiffe-ai/sub: <the prefixed SPIFFE ID>`; variable `test-secret`; `read`/`execute` for that host |
| grant in `conjur/authn-jwt/swa-lab-spiffe-ai` | the host joins the authenticator's `apps` group |

```
==> 1. authenticator authn-jwt/swa-lab-spiffe-ai
HTTP 201
{"type":"jwt","name":"swa-lab-spiffe-ai","enabled":true,"data":{"audience":"https://apj-secrets.secretsmgr.cyberark.cloud","jwks_uri":"https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local/.well-known/jwks","issuer":"https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local"},"created_at":"2026-10-19T03:21:38.348+00:00"}
==> 2. policy branch data/swa-lab-spiffe-ai: host pinned to sub=spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
{"created_roles":{"conjur:host:data/swa-lab-spiffe-ai/ai000-qcheng":{"id":"conjur:host:data/swa-lab-spiffe-ai/ai000-qcheng","api_key":null}},"version":310}
HTTP 201
==> 3. allow the host to use the authenticator
{"created_roles":{},"version":1}
HTTP 201
==> 4. test secret value

HTTP 201
```

Two details worth reading in that output:

- **`"api_key": null`.** The host has no API key at all. The only way to act as
  it is to present a JWT-SVID that passes the authenticator's checks.
- **`"version": 1` on the grant.** Creating an authenticator through
  `/api/authenticators` also creates its `conjur/authn-jwt/<name>` policy and
  `apps` group — the grant would fail if the group were missing.

The authenticator sets no `token_app_property`. The host ID travels in the login
URL instead, and the `sub` annotation pins which token may claim it — the same
scheme SWA's own server registration uses (its `authn_id` decodes to
`.../authn-jwt/swa-server-macos-lab-<id>/conjur/host%2Fcomponent%2F.../authenticate`).

**On a shared tenant, this is the step to review first.** These are Secrets
Manager writes; the script creates only new, uniquely named objects and touches
nothing that exists.

### Test

```bash
scripts/secrets-manager-authn.sh test
```

```
==> start the prefixed agent (ai-prefix-test node group) and fetch its SVID
   prefixed sub: spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
==> restore the baseline agent and fetch its (non-prefixed) SVID
   baseline sub: spiffe://swa-lab.local/macos-unix-ng/workload/qcheng

==> A. authn-jwt with the prefixed SVID  (expect 200)
   HTTP 200
   access token acquired (988 chars)
==> read data/swa-lab-spiffe-ai/test-secret with that token
hello from spiffe://swa-lab.local/ai-prefix-test/workload/AI000-qcheng
   HTTP 200

==> B. authn-jwt with the baseline SVID for the same host  (expect 401)
   HTTP 401
==> C. tampered prefixed SVID  (expect 401)
   HTTP 401
```

**B is the one that matters.** The baseline SVID has a valid RS512 signature
from the same trust domain, the right issuer and audience. It is refused only
because its `sub` does not match the host's annotation — which proves the pin is
enforced, not merely stored. C is refused on the signature.

The script fetches both SVIDs with the tenant URL as audience, and checks that
the prefixed `sub` matches `.env`; if the server is still on an older template it
says so and points at `scripts/spiffe-prefix.sh --restart`.

### Trap: a bare 401 with an empty body

```
==> A. authn-jwt with the AI000 SVID  (expect 200)
   HTTP 401
   body:
```

Conjur login names carry their kind, and a host logs in as **`host/<id>`**:

```
/api/authn-jwt/swa-lab-spiffe-ai/conjur/host%2Fdata%2Fswa-lab-spiffe-ai%2Fai000-qcheng/authenticate
                                         ^^^^^^^
```

Without `host%2F`, the same request is a login for a *user* named
`data/swa-lab-spiffe-ai/ai000-qcheng`, which does not exist. Conjur never tells
the client why a login failed — every cause is the same empty 401 — so check the
URL before suspecting the token. The reason is recorded in the tenant's audit
log.

### The pin is exact, not a prefix match

The annotation matches one `sub`, so the host above admits `AI000-qcheng` and
nothing else — not every `AI*` workload. Admitting a family of identities needs a
different shape: set `token_app_property: sub` with an `identity_path` so each
SPIFFE ID maps to its own host, or give each class of workload its own node group
and authenticator. Neither is tested here.

## 7. Clean up

```bash
scripts/secrets-manager-authn.sh cleanup
scripts/swa-api.sh DELETE \
  /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab/node-groups/ai-prefix-test
scripts/restart-agent.sh
```

`cleanup` deletes the `data/swa-lab-spiffe-ai` policy branch and the
authenticator. **Untested:** it has not been run against the tenant yet.
[`teardown.sh`](08-facilitator-notes.md#teardown) does all of this as part of a
full teardown.

---

Back to the [README](README.md).
