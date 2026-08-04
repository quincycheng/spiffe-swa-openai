# 02 — Trust domain and OIDC discovery

A **trust domain** is the root of a SPIFFE identity namespace. Every SPIFFE ID
issued here begins `spiffe://swa-lab.local/`, and every JWT-SVID is signed by a
key belonging to this trust domain.

```bash
source scripts/swa-auth.sh
```

## Create it

```bash
cat > /tmp/td-body.json <<'JSON'
{
  "name": "swa-lab.local",
  "jwt": {
    "signature_algorithm": "RS512",
    "signing_key_ttl": 86400,
    "signing_key_type": "RSA_4096",
    "token_ttl": 300
  },
  "x509": { "workload_ttl": 3600 }
}
JSON

scripts/swa-api.sh POST /api/swa/trust-domains "$(cat /tmp/td-body.json)"
```

```
HTTP 201
{
  "created_at": "2026-08-04T06:42:31.86127434Z",
  "jwt": {
    "discovery_endpoints": {
      "jwks_uri": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local/.well-known/jwks",
      "oidc_discovery_url": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local/.well-known/openid-configuration"
    },
    "signature_algorithm": "RS512",
    "signing_key_ttl": 86400,
    "signing_key_type": "RSA_4096",
    "token_ttl": 300
  },
  "name": "swa-lab.local",
  "x509": { "workload_ttl": 3600 }
}
```

**Record the two discovery endpoints.** OpenAI needs the issuer derived from
them.

The trust domain name is a namespace label, not a hostname. `swa-lab.local`
never has to resolve in DNS.

### If the trust domain already exists

Re-running the `POST` is safe, but it is not idempotent — you get an explicit
rejection rather than a silent success:

```
HTTP 409
{"code":"conjur_resource_already_exists","message":"Conjur trust_domain with name 'swa-lab.local' already exists ...
hint: resource already exists -- this is idempotent-safe, continue
```

Nothing was modified. Either continue to [03](03-swa-server-kind.md), or check
what is there:

```bash
scripts/swa-api.sh GET /api/swa/trust-domains/swa-lab.local | jq -c '.jwt'
```

To start over, delete it first — but note this destroys **everything beneath it**
(server groups, node groups, registered servers):

```bash
scripts/swa-api.sh DELETE /api/swa/trust-domains/swa-lab.local
```

### Your terminal must not close

If running the `POST` above **closes your terminal window**, you are on an older
copy of `scripts/swa-auth.sh`. The cause and the fix are in
[07](07-troubleshooting.md#sourcing-a-script-closes-your-terminal). The current
scripts do not do this; verify with:

```bash
source scripts/swa-auth.sh
set -o | grep errexit      # must print: errexit  off
```

### Field choices

| Field | Value | Why |
|---|---|---|
| `signature_algorithm` | `RS512` | SWA's default. **Verified accepted by OpenAI** — see below |
| `signing_key_type` | `RSA_4096` | SWA's default |
| `token_ttl` | `300` | 5-minute SVIDs. Short enough to matter, long enough to demo |
| `x509.workload_ttl` | `3600` | Unused in this workshop; X.509-SVIDs are issued but not consumed |

The whole `jwt` object is optional — omitting it produces exactly these defaults.
It is spelled out here so the workshop states its own parameters explicitly.

## Set `TD_URL` once

The three `.well-known` endpoints are used repeatedly from here on. Derive the
base URL from `.env` rather than pasting a hostname — **your tenant subdomain is
not `apj-secrets`**, and the literal URLs shown in these documents come from the
tenant they were written against.

```bash
set -a; source .env; set +a
SWA_API_BASE="$(printf '%s' "${CONJUR_APPLIANCE_URL%/}" | sed -E 's#/api/?$##')"
TD_URL="${SWA_API_BASE}/api/swa/trust-domains/${SWA_TRUST_DOMAIN}"
echo "${TD_URL}"
```

```
https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local
```

The `sed` strips the `/api` suffix that `CONJUR_APPLIANCE_URL` carries but these
paths supply themselves. `TD_URL` is exactly the `iss` claim your SVIDs will
carry, and exactly what you register with OpenAI in
[06](06-openai-federation.md).

`TD_URL` is a plain shell variable, so it is lost when you close the terminal.
Re-run the three lines above in a new shell — later documents assume it is set.

## Verify discovery is publicly reachable

This is the step that proves the no-tunnel architecture. Run it with **no
authorization header at all**:

```bash
curl -sS "${TD_URL}/.well-known/openid-configuration"
```

```json
{
  "id_token_signing_alg_values_supported": ["RS256","RS384","RS512","ES256","ES384","ES512"],
  "issuer": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local",
  "jwks_uri": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local/.well-known/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"]
}
```

HTTP 200, unauthenticated, from the public internet. **This is why no tunnel is
needed.** OpenAI fetches signing keys from this CyberArk URL; it never contacts
your laptop.

### The issuer must satisfy the OIDC convention

Both OpenAI and Anthropic require that appending
`/.well-known/openid-configuration` to the `iss` claim yields a discovery
document whose `issuer` field equals that claim **exactly**. Check it:

```bash
curl -sS "${TD_URL}/.well-known/openid-configuration" | jq -r '.issuer'
echo "${TD_URL}"
```

```
https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local
https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local
```

Or assert it directly:

```bash
[ "$(curl -sS "${TD_URL}/.well-known/openid-configuration" | jq -r '.issuer')" = "${TD_URL}" ] \
  && echo "issuer matches" || echo "MISMATCH"
```

```
issuer matches
```

Byte-identical to `$TD_URL`. Note the issuer is the trust-domain URL *without* the
`.well-known` suffix — that trailing path is what you register with OpenAI, and
getting it wrong is a common misconfiguration.

## The JWKS is empty until a server joins

```bash
curl -sS "${TD_URL}/.well-known/jwks" | jq -c '{n: (.keys|length)}'
```

```
{"n":0}
```

Expected at this stage. The trust domain has no signing keys yet because no SWA
Server has started and uploaded one. It populates in
[03-swa-server-kind.md](03-swa-server-kind.md).

**`{"n":0}` later on means something is wrong.** Once a server has run, an empty
JWKS means no key is published, and every token exchange will fail with
`Invalid subject token.` The usual cause is that the trust domain was deleted and
recreated, which discards its signing keys while leaving the server unaware. See
[07](07-troubleshooting.md#the-jwks-went-empty-after-it-was-working).

## On RS512

Original concern, now settled: SWA defaults to RS512, Anthropic documents RS512
as accepted, but OpenAI's documentation does not enumerate algorithms (its
examples show ES256). If OpenAI had rejected RS512 the fallback was to recreate
the trust domain with `RS256`/`RSA_2048`.

**OpenAI accepts RS512.** Verified by live token exchange in
[06-openai-federation.md](06-openai-federation.md). Keep the defaults.

Should you ever need to change the algorithm, note that the trust domain must be
recreated — and everything beneath it (server group, node group, registered
server) is destroyed with it. Decide the algorithm before building the hierarchy.

---

Next: [03 — SWA Server on kind](03-swa-server-kind.md)
