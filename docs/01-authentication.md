# 01 — Authenticating to the tenant

Every SWA API call needs an access token. Getting one takes two hops:

```
username + password ──▶ CyberArk Identity ──▶ ID token
                                                  │
                              Secrets Manager ◀───┘
                                     │
                                     ▼
                            SWA API access token
```

## Use the script

```bash
source scripts/swa-auth.sh
```

```
authenticated: tenant=AAP4062 base=https://apj-secrets.secretsmgr.cyberark.cloud token_len=976
```

It exports `SWA_TOKEN` and `SWA_API_BASE`. Confirm with a read-only call:

```bash
scripts/swa-api.sh GET /api/swa/trust-domains
```

```
HTTP 200
{"count":0,"trust_domains":[]}
```

Tokens are short-lived. Re-source the script when calls start returning 401.

## The flow, step by step

Understanding this matters because widely-copied examples use a flow that does
not work for a plain admin user. Every command below is runnable as written —
each step extracts what the next one needs with `jq`, so nothing has to be
copy-pasted by hand.

Start by loading `.env`:

```bash
set -a; source .env; set +a
```

### Step 0 — resolve the Identity tenant host

`IDENTITY_TENANT_URL` must be the `*.id.cyberark.cloud` host. If yours points at
the Secrets Manager host instead, these `/Security/*` calls return an empty
**HTTP 302** and every `jq` below silently yields nothing. Derive the real host
from the redirect:

```bash
case "${IDENTITY_TENANT_URL}" in
  *.id.cyberark.cloud*) IDENTITY_URL="${IDENTITY_TENANT_URL%/}" ;;
  *) IDENTITY_URL=$(curl -sS -o /dev/null -D - -X POST "${IDENTITY_TENANT_URL%/}/oauth2/platformtoken" \
       -H 'Content-Type: application/x-www-form-urlencoded' \
       --data-urlencode 'grant_type=client_credentials' \
       | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' \
       | sed -E 's#^(https://[^/]+).*#\1#') ;;
esac
echo "${IDENTITY_URL}"
```

```
https://aap4062.id.cyberark.cloud
```

This is the same resolution `scripts/swa-auth.sh` performs, which is why the
script works even when the variable is wrong. See
[Trap: two different hostnames](#trap-two-different-hostnames).

### Step 1 — start authentication

```bash
START=$(curl -sS -X POST "${IDENTITY_URL}/Security/StartAuthentication" \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg u "${IDSEC_USERNAME}" '{Version:"1.0",User:$u}')")

printf '%s' "$START" | jq '{success, TenantId:.Result.TenantId,
  mechanisms:[.Result.Challenges[].Mechanisms[].Name]}'
```

```json
{
  "success": true,
  "TenantId": "AAP4062",
  "mechanisms": ["UP", "PASSKEY"]
}
```

Your list will differ — it reflects the authentication profile your tenant applies
to this user. All that matters is that `UP` is in it.

The full response also carries a `SessionId` and a `MechanismId` per mechanism.
Capture the three values the next call needs — picking the mechanism named `UP`
(username/password):

```bash
TENANT_ID=$(printf '%s' "$START" | jq -r '.Result.TenantId')
SESSION_ID=$(printf '%s' "$START" | jq -r '.Result.SessionId')
MECH_ID=$(printf '%s' "$START" | jq -r \
  '[.Result.Challenges[].Mechanisms[] | select(.Name=="UP")][0].MechanismId')

echo "TenantId=${TENANT_ID}  SessionId=${#SESSION_ID} chars  MechanismId=${#MECH_ID} chars"
```

```
TenantId=AAP4062  SessionId=44 chars  MechanismId=44 chars
```

The lengths are printed rather than the values, since a `SessionId` is a live
credential for the duration of the login.

If no `UP` appears in `mechanisms`, your tenant does not offer password
authentication to this user and this flow cannot work.

### Step 2 — answer the password challenge

```bash
ADV=$(curl -sS -X POST "${IDENTITY_URL}/Security/AdvanceAuthentication" \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg t "$TENANT_ID" --arg s "$SESSION_ID" \
                   --arg m "$MECH_ID"  --arg a "$IDSEC_SECRET" \
    '{TenantId:$t, SessionId:$s, MechanismId:$m, Action:"Answer", Answer:$a}')")

printf '%s' "$ADV" | jq '{success, Summary:.Result.Summary}'
```

```json
{ "success": true, "Summary": "LoginSuccess" }
```

`Summary: LoginSuccess` means you have an Identity ID token. Building the request
body with `jq --arg` keeps the password out of your shell history and off the
`ps` command line.

```bash
ID_TOKEN=$(printf '%s' "$ADV" | jq -r '.Result.Token')
echo "ID_TOKEN: ${#ID_TOKEN} chars"
```

```
ID_TOKEN: 3149 chars
```

### Step 3 — exchange it for a Secrets Manager access token

Note the base URL here is the **Secrets Manager** host, not the Identity host,
and that `CONJUR_APPLIANCE_URL` already carries the `/api` suffix these paths
supply themselves:

```bash
SWA_API_BASE="$(printf '%s' "${CONJUR_APPLIANCE_URL%/}" | sed -E 's#/api/?$##')"

SWA_TOKEN=$(curl -sS -X POST "${SWA_API_BASE}/api/authn-oidc/cyberark/conjur/authenticate" \
  -H 'Accept-Encoding: base64' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "id_token=${ID_TOKEN}")

echo "SWA_TOKEN: ${#SWA_TOKEN} chars"
```

```
SWA_TOKEN: 976 chars
```

The response is the access token as **plain text**, not JSON — do not pipe it to
`jq`. That is the same 976-character token `scripts/swa-auth.sh` exports.

## Trap: the client-credentials flow does not work here

Several public examples — including the `swa-demos` reference scripts — obtain a
token like this:

```bash
# THIS FAILS for a plain Secrets Manager Admin user
PLATFORM_TOKEN=$(curl -s -X POST "${IDENTITY_TENANT_URL}/oauth2/platformtoken" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${IDSEC_USERNAME}" \
  --data-urlencode "client_secret=${IDSEC_SECRET}" | jq -r '.access_token')
```

Result:

```json
{"error":"access_denied","error_description":"invalid client creds or client not allowed"}
```

That endpoint expects an OAuth **service-user client**, configured separately in
CyberArk Identity. An ordinary Identity user with the Secrets Manager Admin role
is not one, no matter how correct their credentials.

The error is unhelpfully generic — identical for a valid username with a wrong
password, and for a username that does not exist. It gives no signal about
*which* part is wrong, so it is easy to misread as "bad password" and go hunting
for the wrong problem.

**Do not conclude your password is wrong from a 9-character value.** A short
credential looks suspicious for an OAuth client secret, but this field is a user
password. The way to tell them apart is the flow, not the length: if
`StartAuthentication` offers you a `UP` mechanism and `AdvanceAuthentication`
returns `LoginSuccess`, the credential is fine.

## Trap: two different hostnames

`IDENTITY_TENANT_URL` and `CONJUR_APPLIANCE_URL` are different hosts:

| Variable | Host |
|---|---|
| `IDENTITY_TENANT_URL` | `https://<tenant>.id.cyberark.cloud` |
| `CONJUR_APPLIANCE_URL` | `https://<subdomain>.secretsmgr.cyberark.cloud/api` |

Point the Identity URL at the Secrets Manager host and you get an HTTP **302**
rather than an error — a redirect to the real Identity tenant:

```
location: https://aap4062.id.cyberark.cloud/login?redirectUrl=...
```

That redirect is actually the fastest way to discover your Identity tenant ID if
you do not know it. `scripts/swa-auth.sh` follows it automatically, but set the
variable correctly to save the round trip.

Note also that the tenant number embedded in the username
(`user@cyberark.cloud.3434`) is **not** the Identity tenant hostname
(`aap4062.id.cyberark.cloud`). They are unrelated identifiers; do not try to
construct one from the other.

## Trap: HTTP 406 on every SWA API call

A token that works will still produce 406 responses without the versioned
`Accept` header:

```
Accept: application/x.secretsmgr.v2+json
```

Distinguishing the two failures:

| Response | Meaning |
|---|---|
| `401 authorization missing` | Token bad, missing, or wrong scheme |
| `406` (empty body) | Token fine, `Accept` header missing or wrong |

Use `Authorization: Token token="<token>"` — a `Bearer` prefix returns 401.
`scripts/swa-api.sh` sets all of this correctly.

---

Next: [02 — Trust domain](02-trust-domain.md)
