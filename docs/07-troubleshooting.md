# 07 — Troubleshooting

Every failure below was hit while building this workshop, on this hardware, with
this release. Each entry gives the real symptom, the actual cause, and the fix.

Symptoms are grouped by where they surface, because several of these appear far
from their cause.

Snippets here assume `TD_URL` is set and that you have sourced the auth script.
Both take three lines:

```bash
cd /path/to/spiffe-swa-openai
set -a; source .env; set +a
TD_URL="$(printf '%s' "${CONJUR_APPLIANCE_URL%/}" | sed -E 's#/api/?$##')/api/swa/trust-domains/${SWA_TRUST_DOMAIN}"
source scripts/swa-auth.sh
```

---

## Setup and tooling

### `swa-agent` exits silently with code 137

```
$ ./swa-agent version
$ echo $?
137
```

No output, no dialog, no crash report. 137 is SIGKILL.

**Cause:** Gatekeeper. The binary is code-signed by CyberArk but not notarized.

```bash
codesign -dv swa-agent    # signed: CYBERARK SOFTWARE INC. (Y6C5PMT6J8)
spctl -a -vv swa-agent    # rejected, source=Unnotarized Developer ID
```

**Fix:**

```bash
xattr -d com.apple.quarantine swa-agent
```

On a managed laptop with a strict Gatekeeper policy this may not be permitted at
all. Verify before the workshop; there is no workaround from inside the lab.

### `tar: unrecognized option '--one-top-level'`

macOS ships **BSD tar**. Use `mkdir` plus `-C`:

```bash
mkdir -p swa-release-v1.0.2
tar xzf ~/Downloads/swa-release-v1.0.2.tgz -C swa-release-v1.0.2
```

### `openssl x509: Unknown option: -ext`

macOS `openssl` is **LibreSSL**, which has no `-ext`. The portable form:

```bash
openssl x509 -in cert.pem -noout -text | grep -A2 "Subject Alternative Name"
```

### Sourcing a script closes your terminal

**Symptom:** you run `source scripts/swa-auth.sh`, then any command that returns
nonzero — for example `scripts/swa-api.sh POST ...` hitting an HTTP 409 — and the
**terminal window closes instantly**, with no error.

**Cause: `set -e` in a sourced script.** A sourced script runs *in your shell*,
not a subprocess, so its shell options persist after it finishes. `set -euo
pipefail` therefore leaves `errexit` **on** in your interactive shell, and the
next command that returns nonzero terminates the shell — which the terminal
reports as the window closing.

Two things then combine to trigger it:

1. `swa-auth.sh` leaves `errexit` on.
2. `swa-api.sh` legitimately exits 1 on any non-2xx response, so a 409 (trust
    domain already exists) becomes fatal.

Neither is wrong alone. Together they close your terminal on a *recoverable* API
response.

**Check whether you are affected:**

```bash
source scripts/swa-auth.sh
set -o | grep errexit
```

```
errexit               off
```

`off` is correct. If it prints `on`, your copy of `swa-auth.sh` still has
`set -euo pipefail` at the top.

**Fix:** a sourced script must not change shell options. `swa-auth.sh` now uses
explicit error handling instead, and returns rather than exits:

```bash
__swa_fail() { echo "$*" >&2; return 1 2>/dev/null || exit 1; }
```

`return 1 2>/dev/null || exit 1` is the portable idiom for "fail correctly whether
sourced or executed" — `return` outside a function is an error when executed, so
it falls through to `exit`.

**Recovering right now,** if your shell is already in this state:

```bash
set +e        # or just open a new terminal
```

**The general rule:** scripts meant to be `source`d must not call `set -e`;
scripts meant to be executed should. In `scripts/`, only `swa-auth.sh` is sourced.

### `BASH_SOURCE[0]: parameter not set`

Scripts sourced from a `zsh` shell — the macOS default — do not get
`BASH_SOURCE`. `scripts/swa-auth.sh` locates the repo root by walking up from
`$PWD` looking for `.env` instead, which works under both shells.

### Cannot create `/run/swa-agent`

macOS has no `/run`, and **SIP prevents creating one** even as root. The shipped
Ansible template defaults there. Use `/tmp/swa-agent/public/` or a path under
`$HOME` — see [04](04-macos-agent.md).

---

## Authentication

### `{"error":"access_denied","error_description":"invalid client creds or client not allowed"}`

**This is the wrong flow, not the wrong password.** The
`/oauth2/platformtoken` client-credentials grant needs an OAuth *service-user
client* configured in CyberArk Identity. An ordinary Identity user holding the
Secrets Manager Admin role is not one.

**Fix:** use `StartAuthentication` / `AdvanceAuthentication` with the `UP`
mechanism, as `scripts/swa-auth.sh` does. Full walkthrough in
[01](01-authentication.md).

The error text is identical for a nonexistent user, a wrong password, and a valid
user on the wrong flow — so it tells you nothing about which. Do not start
resetting passwords on the strength of it.

### HTTP 302 instead of a token

```
location: https://aap4062.id.cyberark.cloud/login?redirectUrl=...
```

`IDENTITY_TENANT_URL` is pointing at the Secrets Manager host. They are two
different hosts:

| Variable | Host |
|---|---|
| `IDENTITY_TENANT_URL` | `https://<tenant>.id.cyberark.cloud` |
| `CONJUR_APPLIANCE_URL` | `https://<subdomain>.secretsmgr.cyberark.cloud/api` |

Conveniently, the `location` header names your real Identity tenant. The tenant
number in your username (`user@cyberark.cloud.3434`) is **unrelated** to the
Identity hostname (`aap4062.id.cyberark.cloud`) — you cannot derive one from the
other.

### HTTP 406 with an empty body on every API call

Missing the versioned `Accept` header:

```
Accept: application/x.secretsmgr.v2+json
```

Use the status code to tell the two auth failures apart:

| Response | Meaning |
|---|---|
| `401 authorization missing` | Token bad, missing, or wrong scheme |
| `406`, empty body | Token is fine; `Accept` header wrong |

Also: the scheme is `Authorization: Token token="<token>"`. `Bearer` returns 401.
`scripts/swa-api.sh` gets all of this right — use it rather than hand-rolling
curl.

### HTTP 409 `conjur_resource_already_exists`

The resource is already there and nothing was modified. Harmless on a re-run —
continue, or `GET` it to see what exists. To recreate, `DELETE` first, remembering
that deleting a trust domain destroys every server group, node group, and
registered server beneath it.

`swa-api.sh` exits 1 on a 409, as on any non-2xx. That is only dangerous if
`errexit` has leaked into your shell — see
[above](#sourcing-a-script-closes-your-terminal).

### 401 after a while of working fine

The access token is short-lived. Re-source:

```bash
source scripts/swa-auth.sh
```

---

## Server group and CA

### Attestation fails, but the server group was created with HTTP 201

**Cause: a double-escaped CA PEM.** CyberArk's documented recipe emits literal
`\n` sequences for direct splicing into JSON:

```bash
export CA_CERT_PEM=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' ca.crt)
```

Pass that through `jq --arg` and jq escapes the backslash again, storing `\\n`
where newlines belong. **The API accepts it.** Nothing fails until the agent
attests, minutes later, with an error that points nowhere near the CA.

**Fix:** build the payload with `jq --rawfile`, then verify the round trip:

```bash
scripts/swa-api.sh GET /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab \
  | jq -r '.node_attestation.x509pop.ca_certificates' | openssl x509 -noout -subject
```

```
subject= /CN=SWA Node Attestation CA
```

If that errors, the stored PEM is corrupt. Delete the server group and recreate
it — there is no in-place repair.

### `certificate not intended for digital signature use`

```
level=ERROR msg="Failed to attest" error="... unable to generate challenge:
certificate not intended for digital signature use"
```

**Cause:** CyberArk's documented signing command omits `-extfile`, producing a
certificate with **no X509v3 extensions at all**. x509pop is proof-of-possession:
the server will not issue a signing challenge to a certificate that does not
assert `digitalSignature`.

**Diagnose:**

```bash
openssl x509 -in agent.crt -noout -text | grep -c X509v3   # 0 == broken
```

**Fix:** re-sign with an extension file. Full recipe in
[04](04-macos-agent.md#2-generate-the-agent-certificate).

### Attestation rejected with a valid, correctly-signed certificate

The Subject **CN must equal the node group name exactly**. That is how the server
selects the node group.

```bash
openssl x509 -in agent.crt -noout -subject   # subject= /CN=macos-unix-ng
```

---

## Server on kind

### Pod stuck `ImagePullBackOff`

Pass `--set image.pullPolicy=IfNotPresent`. The image exists only inside the kind
node; the default policy tries Docker Hub and fails.

### Pod crash-loops immediately on Apple Silicon

Wrong architecture. Load the **`arm64v8`** archive, not `amd64`:

```bash
kind load image-archive --name swa-lab \
  swa-release-v1.0.2/container-images/swa-server-1.0.0-SNAPSHOT-arm64v8.tar
```

`kind load` prints nothing on success, so confirm explicitly:

```bash
podman exec swa-lab-control-plane crictl images | grep swa
```

The `.env-template` in the public `swa-demos` repository defaults to `amd64`.

### Kubernetes version out of range

SWA 1.0.2 supports **1.33–1.35**. Podman Desktop and Docker Desktop bundle
**1.36.x**. Keep the pin `kindest/node:v1.35.5`.

### Server registration rejected, or the pod cannot reach the control plane

Two things to check.

`audience` must be `conjur` — it must match the `aud` on the projected service
account token the chart mounts.

`controlPlane.url` takes the host **without** the `/api` suffix, whereas
`CONJUR_APPLIANCE_URL` in `.env` includes it. The scripts strip it; the Helm flag
does not.

### The cluster's `jwks_uri` is unreachable from CyberArk

```json
{"issuer":"https://kubernetes.default.svc.cluster.local","jwks_uri":"https://10.89.2.2:6443/openid/v1/jwks"}
```

An internal service name and a private IP — CyberArk cannot fetch either. Use the
**`public_keys`** registration path: fetch `/openid/v1/jwks` locally and register
the keys inline. See [03 step 5](03-swa-server-kind.md).

---

## Agent and SVIDs

### `no generator for nodegroup`

```
ERROR ... failed to get identity for workload: no generator for nodegroup
```

The agent is attested; the server has not synced the node group you created after
it started. `syncInterval` is **15 minutes**.

```bash
kubectl rollout restart deploy/swa-server -n swa-system
kubectl rollout status deploy/swa-server -n swa-system --timeout=180s
kubectl get pods -n swa-system          # wait for Running
```

Wait for the new pod to reach `1/1 Running`, then re-fetch. **The agent does not
need restarting** — it reconnects (`CONNECTING` → `READY`) and keeps its
attestation. Full recipe:
[04](04-macos-agent.md#trap-no-generator-for-nodegroup).

To avoid it: create node groups **before** installing the server.

### `certificate signed by unknown authority ... "firefly root"`

```
error="could not open attestation stream to SPIRE server: ... tls: failed to
verify certificate: x509: certificate signed by unknown authority (possibly
because of \"x509: ECDSA verification failure\" while trying to verify candidate
authority certificate \"firefly root\")"
```

The agent's cached trust bundle has **no root in common** with the chain the server
is presenting. Restart the agent; it re-fetches the current bundle from
`.well-known/ca-bundles` at startup:

```bash
scripts/restart-agent.sh
```

**This is rarer than it looks, and a plain server restart does not cause it.** The
pod does generate a new self-signed root CA on every start and does not persist it,
but that root is uploaded to the control plane and `.well-known/ca-bundles`
*accumulates* roots rather than replacing them, so an agent holding an older bundle
still chains successfully. Verified: the agent survived a rolling restart, two
back-to-back restarts, a `scale 0` → `scale 1` cycle, and a 90-second outage.

What actually triggers it is a bundle **reset** — deleting and recreating the trust
domain or server group, or a `teardown.sh` followed by a rebuild. See
[the JWKS went empty](#the-jwks-went-empty-after-it-was-working).

Your `x509pop` agent certificate is **not** implicated — this is the server's CA,
not yours. Do not regenerate agent certificates in response to this error.

Confirm which failure you have before acting. If `Failed to attest` is **zero**, this
is not your problem — you have the
[silent-exit failure](#the-agent-log-ends-in-stopped-with-no-attestedtrue-and-no-errors)
instead, whose usual cause is a duplicate agent process. The chain check in
[04](04-macos-agent.md#trap-certificate-signed-by-unknown-authority-firefly-root)
settles it in one `openssl verify`.

### The agent cannot verify the server's TLS certificate — *hostname* mismatch

It does not need to match the hostname. **SPIFFE mTLS validates the URI SAN**
(`spiffe://swa-lab.local/server`), not the DNS name, so `addr: 127.0.0.1:8443`
works even though the certificate says `server.swa-lab.local`.

No `/etc/hosts` entry and **no `sudo`** are required anywhere in this workshop.

Do **not** reach for `bootstrap.insecure: true`. The trust bundle is available
from the public, authenticated `.well-known/ca-bundles` endpoint; disabling
verification in a zero-trust workshop undercuts the premise. It would also not fix
the `firefly root` error above — the correct fix there is a restart, not disabling
verification.

### The agent log ends in `Stopped`, with no `attested=true` and no errors

The agent was **signalled to exit**, not rejected. `"Shutting down, context
cancelled"` and `Stopping subsystem=swa-agent` within a second of startup mean a
`SIGHUP`/`SIGTERM` arrived. **Both counts zero — `attested=true` 0 *and*
`Failed to attest` 0 — is the signature.** A certificate or trust-bundle problem
always produces a non-zero error count.

Most likely you started a second agent while one was running. The second exits
because the socket is taken, but it deletes that socket and truncates the log on the
way through, so the first agent is now unreachable too:

```bash
pgrep -fl "swa-agent run" | wc -l    # must be 1
pkill -f "swa-agent run"; sleep 2
scripts/restart-agent.sh
```

The other cause is a bare `&` instead of `nohup ... &`, so the agent died with its
terminal. Use the `nohup` form. See
[04](04-macos-agent.md#trap-the-log-looks-like-a-clean-shutdown) for the annotated
log, including the three lines in it that look like faults but are not.

### The agent crashes on first attestation

If you enabled the `docker` workload attestor, remove it. **It crashes the 1.0.2
agent.** Use `unix` only.

### `connection refused` on the agent socket

Check the NodePort patch from [03 step 8](03-swa-server-kind.md) was applied —
the chart defaults to `ClusterIP` and exposes no NodePort field, so nothing is
listening on `127.0.0.1:8443` without it.

```bash
kubectl get svc swa-server -n swa-system
nc -z 127.0.0.1 8443 && echo reachable
```

---

## OpenAI federation

### `Invalid subject token.`

OpenAI returns this same opaque message for every rejection cause. Work through
them in order:

1. **Issuer mismatch.** The console field must equal the token's `iss` exactly,
   with **no** `.well-known` suffix.
2. **Audience mismatch.** `https://api.openai.com/v1` — with `/v1`, no trailing
   slash — in both the console and the `-a` argument to `fetch-svid.sh`.
3. **Subject mismatch.** The mapping value must be the exact SPIFFE ID, which
   embeds *your* Unix username.
4. **Expired token.** SVIDs live 300 seconds. Fetch a fresh one.
5. **JWKS empty.** No signing key is published, so nothing can verify:

   ```bash
   curl -sS "${TD_URL}/.well-known/jwks" | jq '.keys|length'   # must be >= 1
   ```

   See the next entry if this returns `0` after the lab was working.

Decode what you actually sent and diff it against the console, field by field:

```bash
python3 -c 'import base64,json;t=open("/tmp/svid-openai.jwt").read().strip().split(".")[1];print(json.dumps(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4))),indent=2))'
```

### The JWKS went empty after it was working

**Symptom:** everything worked, then every exchange started failing with
`Invalid subject token.` and:

```bash
curl -sS "${TD_URL}/.well-known/jwks" | jq -c '{n:(.keys|length)}'
```

```json
{"n":0}
```

Meanwhile the server pod is crash-looping, and its log says:

```
msg="Control plane returned non-200 when fetching configuration" status=401
conjur authentication failed: status 401
```

**Cause: the trust domain was deleted and recreated.** `created_at` is the tell —
compare it against when you built the lab:

```bash
scripts/swa-api.sh GET /api/swa/trust-domains/swa-lab.local | jq -r '.created_at'
```

```
2026-08-04T10:01:50.284871461Z     # was 06:42:31 -- it was recreated
```

Deleting a trust domain destroys **everything beneath it**: the server group, the
node group, and the server registration — including its `authn_id`. Recreating the
trust domain does not recreate any of them. The running server still holds the old
`authn_id`, which no longer exists, so its authentication to the control plane
returns 401, it can never fetch configuration, and it never uploads a signing key.
Hence `{"n":0}`.

Confirm the hierarchy is gone. Every list endpoint returns a `count`, so ask for
all three levels at once:

```bash
for p in server-groups \
         server-groups/macos-lab/node-groups \
         server-groups/macos-lab/components; do
  printf '%-46s ' "${p}"
  scripts/swa-api.sh GET "/api/swa/trust-domains/swa-lab.local/${p}" 2>/dev/null | jq -c '{count}'
done
```

After a recreate, all three are empty:

```
server-groups                                  {"count":0}
server-groups/macos-lab/node-groups            {"count":0}
server-groups/macos-lab/components             {"count":0}
```

A healthy lab reports `{"count":1}` on each. Use `jq '{count}'` and not
`jq 'length'` — these responses are envelopes (`{"count":1,"server_groups":[...]}`),
so `length` counts the *envelope's* keys and always returns 2.

**Your local key material survives** — `artifacts/ca.key`, `artifacts/ca.crt` and
the agent certificate are still valid, because the CA is yours, not the control
plane's. You do not need to regenerate certificates.

**Recovery, in this order:**

1. Recreate the server group with the *same* CA
   ([03 step 2](03-swa-server-kind.md#2-create-the-server-group)) and verify the
   PEM round trip.
2. Recreate the node group
   ([04 step 1](04-macos-agent.md#1-create-the-node-group)).
3. Re-register the server ([03 step 5](03-swa-server-kind.md#5-register-the-server)).
   **You get a new `authn_id`** — this is the part that fixes the 401.
4. Push it into the running deployment:

   ```bash
   AUTHN_ID=$(jq -r '.authn_id' /tmp/comp.json)
   helm upgrade swa-server /tmp/chart/swa-server -n swa-system --reuse-values \
     --set controlPlane.auth.authnID="${AUTHN_ID}" --wait --timeout 180s
   ```

   If this fails with `conflict with "kubectl-patch" using v1: .spec.type`, see
   [03 step 8](03-swa-server-kind.md#8-pin-the-nodeport-to-30443) — a past
   `kubectl patch --type merge` on `spec.type` has taken ownership of the field.
5. Confirm a key was uploaded, then restart the agent so it re-attests:

   ```bash
   kubectl logs -n swa-system deploy/swa-server --tail=40 | grep KeyUploaded
   curl -sS "${TD_URL}/.well-known/jwks" | jq -c '{n:(.keys|length)}'
   ```

   ```json
   {"n":1}
   ```

**OpenAI needs no reconfiguration.** The issuer URL and the SPIFFE ID are derived
from the trust-domain name and the node group name, both unchanged — only the
signing key rotated, and discovery mode re-fetches the JWKS on demand. This is a
second, less obvious argument for discovery mode over uploaded JWKS: an uploaded
copy would now be stale and would have to be replaced by hand.

**Avoid it entirely:** never `DELETE` a trust domain to "reset" a *running* lab. A
409 on `POST /api/swa/trust-domains` means it already exists and nothing was
modified — just continue.

Deleting the trust domain is only correct as part of a **full** teardown, where
everything beneath it is being rebuilt anyway. `scripts/teardown.sh` does exactly
that, in the right order, and stops the agent and deletes the cluster first — see
[08](08-facilitator-notes.md#teardown). The failure in this section comes from
deleting the trust domain *without* rebuilding its children.

### `401 Invalid identity_provider_id`

The ID is wrong, or belongs to a different organization. Copy it from the console
rather than from any example — the live console issues `idp_...` and `user-...`,
while the documentation shows `wip_...` and `svac_...`.

### Service account rejected

The `(identity_provider_id, service_account_id)` pair must be unique. Create a
new service account rather than reusing one across providers.

### The Workload Identity Federation page is not visible

You are not an **owner** of the organization. Members cannot configure it.

### `You have no credits remaining`

**Authentication succeeded.** This is a billing state reached only *after* the
identity is accepted. Confirm auth independently:

```bash
curl -sS https://api.openai.com/v1/models \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" -o /dev/null -w '%{http_code}\n'
```

`200` means the federation works. Add credits if you want a completion on screen.

### Clock skew

Both providers reject tokens with `iat` in the future. If the kind VM's clock
drifts from the tenant's, exchanges fail with — again —
`Invalid subject token.`

```bash
scripts/fetch-svid.sh openai > /tmp/skew-check.jwt
python3 -c 'import base64,json,time;t=open("/tmp/skew-check.jwt").read().strip().split(".")[1];c=json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4)));print("iat offset from local now:",c["iat"]-int(time.time()))'
```

```
iat offset from local now: 0
```

**Fetch a fresh token first.** The offset is measured against `iat`, so it grows
by one second for every second the file has been sitting on disk — checking an old
SVID reports a large offset that has nothing to do with clock skew.

On a fresh token, 0 to a couple of seconds is healthy. Tens of seconds means real
drift. Step the VM clock — quicker than restarting the Podman machine:

```bash
podman machine ssh 'sudo chronyc -a makestep'
```

Observed after the Mac had slept: the VM was 52 seconds behind while chrony
reported `System clock synchronized: yes`, because it had marked every source
unusable. `makestep` brought it to within a second.

The same drift also breaks **agent attestation** with a freshly signed
certificate (`certificate has expired or is not yet valid ... current time ... is
before ...`): see [09](09-prefix-and-secrets-manager.md#trap-certificate-has-expired-or-is-not-yet-valid-on-a-brand-new-certificate).

---

## Known rough edges in `1.0.0-SNAPSHOT`

This is a pre-release build. Confirmed issues:

- The `docker` workload attestor crashes the agent.
- `SHA256SUMS` lists `swa-server_*_darwin_arm64.tar.gz`, but **no server binary
  ships for any platform**. It is a build-wide manifest, not a description of
  this package. Do not go looking for the file.
- The native macOS agent binary is undocumented but functional — the published
  docs only describe Linux VM installs via Ansible.

---

Next: [08 — Facilitator notes](08-facilitator-notes.md)
