# Zero Secrets: SPIFFE → OpenAI with CyberArk Secure Workload Access

A hands-on workshop. A process on a macOS laptop calls the OpenAI API with **no
API key** — no `sk-...` string exists at any point, in any file, in any
environment variable.

Instead the workload proves *what it is* with a cryptographically attested
SPIFFE identity, and OpenAI exchanges that proof for a 5-minute access token.

Every command in these documents was executed against a real CyberArk tenant and
a real OpenAI organization. Outputs are transcribed, not invented. Where
something is untested, it says so.

---

## The problem: secret zero

Conventional API access begins with a long-lived key. That key must be created,
stored, distributed, rotated, and revoked — and it is a bearer credential, so
anyone holding a copy is indistinguishable from the legitimate workload. Protect
it with a secrets manager and you have only moved the problem: now the workload
needs a credential to authenticate to the secrets manager. That irreducible
first credential is **secret zero**.

Workload identity federation dissolves it. The workload holds no secret at all.
It presents a short-lived, signed assertion of its own identity, issued by an
authority the API provider already trusts.

## What actually happens

![Architecture](images/01-architecture.png)

1. The workload asks the local SWA Agent for a JWT-SVID over a Unix socket.
2. The agent has already attested itself to the SWA Server with a certificate
   (x509pop). The server checks *which Unix user* is calling and derives a
   SPIFFE ID.
3. The SWA Server publishes its JWT signing key to the CyberArk SaaS control
   plane.
4. The workload posts the JWT-SVID to OpenAI's token endpoint.
5. OpenAI fetches the public JWKS **from CyberArk's cloud** and verifies the
   signature.
6. OpenAI returns an access token valid for 299 seconds.

## The insight that makes this work on a laptop

**OpenAI never connects to your laptop.**

Because Secure Workload Access is a SaaS control plane, the JWKS lives on a
public CyberArk URL. OpenAI fetches keys from there. Your laptop only ever makes
outbound calls.

That is why this workshop needs no ngrok, no tunnel, no port forwarding, no
public DNS, and no uploaded JWKS blob. A self-hosted SPIRE server on a laptop
*cannot* do this — you would have to expose its OIDC Discovery Provider to the
internet. Here, the SaaS control plane is the public surface.

## Documents

Read in order. Each one gates the next — the ordering is not cosmetic. The three
steps marked ⚠️ in the diagram fail confusingly when taken out of order, and
together they account for most of [07](07-troubleshooting.md).

![Build order](images/04-build-order.png)

| # | Document | What it covers |
|---|---|---|
| 00 | [Prerequisites](00-prerequisites.md) | Tooling, entitlements, `.env`, Apple Silicon caveats |
| 01 | [Authentication](01-authentication.md) | Tenant auth — **the flow most examples get wrong** |
| 02 | [Trust domain](02-trust-domain.md) | Trust domain, OIDC discovery, signing algorithm |
| 03 | [SWA Server on kind](03-swa-server-kind.md) | Server group, x509pop CA, kind cluster, Helm install |
| 04 | [macOS agent](04-macos-agent.md) | De-quarantine, node group, agent cert, run, attest |
| 05 | [Fetch and verify SVIDs](05-fetch-svid.md) | Fetch JWT-SVIDs, verify RS512 against public JWKS |
| 06 | [OpenAI federation](06-openai-federation.md) | Console setup, token exchange, negative tests |
| 07 | [Troubleshooting](07-troubleshooting.md) | Every failure hit while building this, with fixes |
| 08 | [Facilitator notes](08-facilitator-notes.md) | Timings, pre-baking, teardown, demo script |

## Scripts

Everything the documents run is in `scripts/`, so a step can be repeated without
re-reading its prose.

| Script | Purpose |
|---|---|
| `swa-auth.sh` | Authenticate to the tenant; exports `SWA_TOKEN`, `SWA_API_BASE`. **Source it** |
| `swa-api.sh` | `METHOD PATH [BODY]` wrapper with the two headers the API requires |
| `restart-agent.sh` | Stop, clear the socket, start **one** agent, verify attestation |
| `fetch-svid.sh` | Fetch a JWT-SVID for an audience (default: OpenAI) |
| `exchange-openai.sh` | Exchange an SVID for an OpenAI access token, then call the API |
| `verify-federation.sh` | The negative tests — run this one live |
| `teardown.sh` | Remove everything, in reverse order |

## Verified results

| Claim | Evidence |
|---|---|
| Agent attests natively on macOS | `attested=true` in agent log |
| SPIFFE ID issued | `spiffe://swa-lab.local/macos-unix-ng/workload/qcheng` |
| Token signed RS512, verifiable from public JWKS | Signature verified against published JWKS |
| **OpenAI accepts RS512** | Token exchange returned an access token |
| Authentication succeeds | `GET /v1/models` → **HTTP 200** |
| Access token is short-lived | `exp - iat` = **299 seconds** |
| Forged and tampered tokens are refused | 3 of 4 negative tests rejected |
| OpenAI records the attested identity | `wif_external_subject` = the SPIFFE ID, inside the access token |
| No API key anywhere | `grep -rE 'sk-(proj-)?[A-Za-z0-9]{20,}' docs/ scripts/` → no matches |

One thing does **not** work on the tenant used here: the final inference call
returns `You have no credits remaining`. That is a billing state reached only
*after* authentication succeeds — `GET /v1/models` returning 200 with no API key
is the proof that matters. See
[06](06-openai-federation.md#the-inference-call-and-one-caveat).

## Scope

**In scope:** SPIFFE identity issuance via CyberArk SWA, and federation to the
OpenAI API with zero secrets.

**Out of scope:** Claude via **AWS Bedrock**, which authenticates with AWS
SigV4/IAM rather than SPIFFE JWT-SVIDs. Anthropic's first-party WIF does support
SPIFFE, but it requires a Claude Console organization; if you reach Claude
through Bedrock, that path does not apply to you. A zero-secret route to Bedrock
exists — AWS IAM Roles Anywhere consuming the **X.509**-SVID that this same
trust domain already issues — but it is not covered or tested here.
