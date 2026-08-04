# 05 — Fetch and verify a JWT-SVID

The agent is attested. Any local process that can reach the socket may now ask
for its own identity — with no credential of its own.

## 1. Fetch an SVID

```bash
scripts/fetch-svid.sh openai > /tmp/svid-openai.jwt
wc -c < /tmp/svid-openai.jwt
```

```
1101
```

The script wraps one command:

```bash
swa-agent api fetch jwt \
  -a "https://api.openai.com/v1" \
  -s /tmp/swa-agent/public/api.sock \
  --output json | jq -r '.[0].svids[0].svid'
```

Two things to notice.

**The audience is required.** JWT-SVIDs are audience-bound at issuance; a token
minted for OpenAI is not usable anywhere else. Proof of that lands in the
negative tests in [06](06-openai-federation.md).

**Nothing here is a secret.** The command passes no password, no token, no key.
Authorisation comes entirely from *which process is calling the socket*, which
the `unix` attestor determines from the caller's kernel-reported UID and path.
That is the whole point of the workshop.

## 2. Decode the header

```bash
python3 - <<'PY'
import base64, json
tok = open('/tmp/svid-openai.jwt').read().strip()
h = tok.split('.')[0]
h += '=' * (-len(h) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(h)), indent=2))
PY
```

```json
{
  "alg": "RS512",
  "kid": "ad6bc4ce-0a94-47ed-8657-1f7177ca7254",
  "typ": "JWT"
}
```

`kid` must be present — **OpenAI rejects tokens without it**, because it needs
the `kid` to select a key from the published JWKS. SWA always sets it, and the
value matches the `KeyUploaded kid=...` line from the server log in
[03](03-swa-server-kind.md). It changes whenever the server regenerates its
signing key — for example after a `rollout restart` — so expect a different UUID
than the one shown here.

`alg` is `RS512`. OpenAI's documentation does not enumerate accepted algorithms
and its examples show ES256, which made this the second open risk of the design.
It is accepted — verified in [06](06-openai-federation.md).

## 3. Decode the payload

```bash
python3 - <<'PY'
import base64, json
tok = open('/tmp/svid-openai.jwt').read().strip()
p = tok.split('.')[1]
p += '=' * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(c, indent=2))
print("lifetime:", c['exp'] - c['iat'], "seconds")
PY
```

```json
{
  "aud": ["https://api.openai.com/v1"],
  "exp": 1785835050,
  "iat": 1785834750,
  "iss": "https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local",
  "nbf": 1785834750,
  "sub": "spiffe://swa-lab.local/macos-unix-ng/workload/qcheng"
}
```

```
lifetime: 300 seconds
```

Claim by claim:

| Claim | Value | Significance |
|---|---|---|
| `sub` | `spiffe://swa-lab.local/macos-unix-ng/workload/qcheng` | The SPIFFE ID. This exact string goes in the OpenAI mapping |
| `aud` | `["https://api.openai.com/v1"]` | An array, even for one audience |
| `iss` | trust-domain URL | Must match the OpenAI issuer field byte-for-byte |
| `iat` / `exp` | 300s apart | The `token_ttl` from [02](02-trust-domain.md) |
| `nbf` | equal to `iat` | Not-before. Valid immediately, so clock skew is the only way it bites |

`iss` is the trust-domain URL **without** any `.well-known` suffix. Providers
append `/.well-known/openid-configuration` themselves.

The `sub` embeds your Unix username. Every attendee's SPIFFE ID differs — see
[06](06-openai-federation.md) for how that shapes the console mapping.

There is no `jti`. Neither provider requires one.

## 4. Verify the signature against the public JWKS

This is the step that demonstrates the architecture. Fetch the key from
CyberArk's public endpoint — the same URL OpenAI will use — and verify the
signature locally.

`TD_URL` comes from [02](02-trust-domain.md#set-td_url-once) — re-derive it if this
is a new shell.

```bash
curl -sS "${TD_URL}/.well-known/jwks" > /tmp/jwks.json

python3 - <<'PY'
import base64, hashlib, json

def b64u(s): return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))

tok = open('/tmp/svid-openai.jwt').read().strip()
h_b64, p_b64, s_b64 = tok.split('.')
kid = json.loads(b64u(h_b64))['kid']

jwk = next(k for k in json.load(open('/tmp/jwks.json'))['keys'] if k['kid'] == kid)
n = int.from_bytes(b64u(jwk['n']), 'big')
e = int.from_bytes(b64u(jwk['e']), 'big')

sig = int.from_bytes(b64u(s_b64), 'big')
recovered = pow(sig, e, n).to_bytes((n.bit_length() + 7) // 8, 'big')

# PKCS#1 v1.5 DigestInfo prefix for SHA-512
prefix = bytes.fromhex('3051300d060960864801650304020305000440')
digest = hashlib.sha512(f"{h_b64}.{p_b64}".encode()).digest()
expected = b'\x00\x01' + b'\xff' * (len(recovered) - len(prefix) - len(digest) - 3) \
           + b'\x00' + prefix + digest

print("kid found in public JWKS:", jwk['kid'] == kid)
print("RS512 signature valid   :", recovered == expected)
PY
```

```
kid found in public JWKS: True
RS512 signature valid   : True
```

Pure standard library — no `cryptography`, no `PyJWT`, nothing to install. The
maths is RSA verification by hand: raise the signature to the public exponent,
then compare against the expected PKCS#1 v1.5 padded SHA-512 DigestInfo.

What this proves, and why it is the crux of the design:

- The signing key lives in the SWA control plane. The laptop never holds it.
- Its **public** half is on the public internet, unauthenticated.
- Therefore **any** relying party — OpenAI, Anthropic, your own service — can
  validate this token without reaching your laptop.

No tunnel. No ngrok. No inbound firewall rule. Self-hosted SPIRE on a laptop
cannot do this, because its JWKS is not publicly reachable; you would have to
upload keys manually and re-upload on every rotation.

## 5. Watch it rotate

```bash
scripts/fetch-svid.sh openai > /tmp/svid-2.jwt
diff <(cat /tmp/svid-openai.jwt) <(cat /tmp/svid-2.jwt) >/dev/null && echo same || echo different
```

```
different
```

Each fetch mints a fresh 300-second token. Nothing is cached on disk, and nothing
needs to be. Compare that with an `sk-...` key sitting in `.env` until someone
remembers to rotate it.

## Fetch for a different audience

```bash
scripts/fetch-svid.sh https://example.com/some-audience > /tmp/svid-other.jwt
```

The script's default is `openai`; any other argument is treated as a literal
audience string. Useful for the negative tests.

---

Next: [06 — OpenAI federation](06-openai-federation.md)
