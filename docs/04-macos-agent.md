# 04 — The native macOS agent

The SWA Agent runs as an ordinary macOS process. No container, no VM, no Ansible.
It attests itself to the server with a certificate, then serves a Workload API
socket that local processes use to fetch their own identities.

## 1. Create the node group

**Do this only after the server is running** ([03](03-swa-server-kind.md)) — the
node group must exist in the server's synced configuration.

```bash
source scripts/swa-auth.sh

scripts/swa-api.sh POST \
  /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab/node-groups \
  '{"name":"macos-unix-ng","description":"macOS native agent unix workloads","workload_type":"unix"}'
```

```
HTTP 201
{
  "name": "macos-unix-ng",
  "workload_configuration": {
    "spiffe_id_template": "spiffe://{{ .trustdomain }}/{{ .nodegroup }}/workload/{{ .unix.user }}",
    "workload_registration_policies": []
  },
  "workload_type": "unix"
}
```

Note the returned `spiffe_id_template`. It determines the identity every workload
gets:

```
spiffe://swa-lab.local/macos-unix-ng/workload/<your unix username>
```

**Your Unix username becomes part of your SPIFFE ID.** Every attendee will
therefore have a *different* SPIFFE ID. This has direct consequences for the
OpenAI mapping in [06](06-openai-federation.md) — plan for it.

An empty `workload_registration_policies` array means every workload on an
attested node receives its own identity. Add CEL policies (for example
`unix.user == 'appuser'`) to restrict issuance.

## 2. Generate the agent certificate

**The Subject CN must equal the node group name exactly.** That is how the server
decides which node group a node joins.

```bash
cd artifacts
openssl genrsa -out agent.key 2048
openssl req -new -key agent.key -out agent.csr -subj "/CN=macos-unix-ng"
```

Now sign it — but not with the command the documentation gives:

```bash
cat > x509pop-ext.cnf <<'CNF'
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
basicConstraints = critical,CA:FALSE
CNF

openssl x509 -req -days 365 -in agent.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -extfile x509pop-ext.cnf -out agent.crt
```

Verify the extension is present:

```bash
openssl x509 -in agent.crt -noout -text | grep -A2 "Key Usage"
```

```
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment
X509v3 Extended Key Usage:
    TLS Web Client Authentication
X509v3 Basic Constraints: critical
```

`Digital Signature` on the first line is the one that matters.

### Trap: the documented signing command produces an unusable certificate

CyberArk's documentation omits `-extfile`:

```bash
# Produces a certificate with NO X509v3 extensions at all
openssl x509 -req -days 365 -in agent.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out agent.crt
```

Attestation then fails:

```
level=ERROR msg="Failed to attest" error="... unable to generate challenge:
certificate not intended for digital signature use"
```

x509pop is *proof of possession*: the server sends a challenge that the agent
must sign with its private key. Without `keyUsage = digitalSignature`, the server
refuses to issue the challenge. The certificate is otherwise perfectly valid —
correct CN, correct CA, in date — which makes this confusing to diagnose.

Checking for the absence of extensions is quick:

```bash
openssl x509 -in agent.crt -noout -text | grep -c X509v3   # 0 means broken
```

## 3. Write the agent configuration

`agent-config/config.yaml`:

```yaml
trustDomain:
  name: swa-lab.local

bootstrap:
  bundleSourceUrl: https://apj-secrets.secretsmgr.cyberark.cloud/api/swa/trust-domains/swa-lab.local/.well-known/ca-bundles
  insecure: false

servers:
  - addr: 127.0.0.1:8443

agent:
  socketPath: /tmp/swa-agent/public/api.sock
  nodeAttestor:
    type: x509pop
    config:
      cert: x509pop.cert
      key: x509pop.key

workload:
  attestors:
    - type: unix
      config:
        discover_workload_path: true
        workload_size_limit: 0

telemetry:
  logging:
    level: debug
```

```bash
cp artifacts/agent.crt agent-config/x509pop.cert
cp artifacts/agent.key agent-config/x509pop.key
chmod 600 agent-config/x509pop.key
```

Four deliberate choices, each differing from the shipped Ansible template:

**`bootstrap.insecure: false`.** The public `.well-known/ca-bundles` endpoint
supplies the trust bundle over authenticated TLS, so trust-on-first-use is
unnecessary. Verify it yourself:

```bash
curl -sS "${TD_URL}/.well-known/ca-bundles" | jq -c '{n:(.bundles|length)}'
```

(`TD_URL` comes from [02](02-trust-domain.md#set-td_url-once) — re-derive it if
this is a new shell. Note the `bundleSourceUrl` in the config above must be the
literal expanded URL; YAML does not interpolate shell variables.)

```json
{"n":1}
```

Any count of 1 or more is fine — like the JWKS, this grows to `{"n":2}` after a
server restart. What matters is that it is not empty and needs no credential to
read.

Setting `insecure: true` in a zero-trust workshop would undercut the entire
premise. It is not needed.

**`socketPath` is not under `/run`.** The Ansible template defaults to
`/run/swa-agent/`. **macOS has no `/run`, and SIP prevents creating one.** Use
`/tmp/swa-agent/public/` or a path under `$HOME`.

**`addr: 127.0.0.1:8443`.** Works despite the cert's `server.swa-lab.local` SAN,
because SPIFFE validates the URI SAN. See [03 step 9](03-swa-server-kind.md).

**`unix` attestor only.** The `docker` attestor is documented but **crashes the
1.0.2 agent** on first attestation. Do not enable it.

## 4. Run the agent

Start from a clean slate. **Never start a second agent while one is running** — the
new process cannot bind the socket, exits within a second, deletes the socket the
healthy agent was serving, and its `>` truncates the log you were reading. You end
up with two broken agents and a log that looks like failed attestation. See
[the clean-shutdown trap](#trap-the-log-looks-like-a-clean-shutdown) below:

```bash
pkill -f "swa-agent run" 2>/dev/null; sleep 2
rm -f /tmp/swa-agent/public/api.sock
mkdir -p /tmp/swa-agent/public

nohup swa-release-v1.0.2/binaries/swa-agent_1.0.0-SNAPSHOT_darwin_arm64/swa-agent \
  run -d agent-config > /tmp/agent.log 2>&1 &
```

The `-d` flag takes a *directory*; `config.yaml` is read from inside it, and the
`cert`/`key` paths are relative to it.

`nohup` and the truncating `>` matter. Without `nohup` the agent dies when the
terminal closes; without truncation you are reading a log that still contains the
previous run's lines, and every count below is wrong.

Give it about 10 seconds before checking anything — attestation is a network round
trip.

Confirm attestation. Check all four together, because any one of them alone
can mislead you:

```bash
echo "running : $(pgrep -f 'swa-agent run' || echo NO)"
echo "attested: $(grep -ac 'attested=true' /tmp/agent.log)"
echo "errors  : $(grep -ac 'Failed to attest' /tmp/agent.log)"
ls -l /tmp/swa-agent/public/api.sock
```

```
running : 80932
attested: 5
errors  : 0
srw-rw-rw-@ 1 qcheng  wheel  0  4 Aug 19:27 /tmp/swa-agent/public/api.sock
```

A healthy agent has a live PID, a non-zero `attested` count, **zero** errors, and
a socket. `attested: 0` with `errors: 0` is a different failure from `attested: 0`
with `errors: 2` — read the error count before concluding anything.

**The `-a` is not optional.** The agent writes occasional non-UTF-8 bytes to its
log, so `grep` classifies the file as binary and prints nothing at all — exit
code 1, no output, exactly as if attestation had failed. `-a` forces it to treat
the file as text. Every `grep` against `/tmp/agent.log` in these documents uses
it.

```bash
grep -c  "attested=true" /tmp/agent.log   # 0 matches -- misleading!
grep -ac "attested=true" /tmp/agent.log   # 5 -- the truth
```

The log sequence to look for:

```
msg="Starting node attestation" system=swa-agent subsystem=node-attestator
msg="Finished node attestation" system=swa-agent subsystem=node-attestator
msg="New leased connection" attested=true active=true state=READY
msg="Skipping re-attestation" attested=true reAttest=false
```

The agent is now attested and serving identities to local processes.

## Trap: the log looks like a clean shutdown

This log is alarming and almost entirely benign:

```
level=DEBUG msg="Starting agent trust bootstrap"
level=DEBUG msg="Failed to find bootstrap bundle file in the agent's filesystem"
level=DEBUG msg="Attempting to load the bootstrap bundle from remote source"
level=INFO  msg=Starting  subsystem=swa-agent
level=INFO  msg=Starting  subsystem=health-server address=127.0.0.1:8082
level=INFO  msg=Started   subsystem=health-server
level=INFO  msg=Stopped   subsystem=health-server
level=INFO  msg=Starting  subsystem=api-server address=/tmp/swa-agent/public/api.sock
level=INFO  msg="Shutting down, context cancelled" subsystem=jwt-manager
level=INFO  msg=Stopping  subsystem=swa-agent
level=DEBUG msg="New leased connection" attested=false active=true state=READY
level=INFO  msg=Stopped   subsystem=swa-agent
```

Three of those lines are **not** faults:

- **`Failed to find bootstrap bundle file`** is expected on a first run at DEBUG
  level. The next line says what it does instead: fetches the bundle from the
  `bundleSourceUrl`. There is no bundle on disk by design.
- **`health-server ... Started` then immediately `Stopped`** is normal startup
  churn.
- **`attested=false`** on the first `New leased connection` is the state
  *before* attestation. The `attested=true` lines come later.

What *is* a fault is the sequence `Stopping subsystem=swa-agent` →
`"Shutting down, context cancelled"` → `Stopped subsystem=swa-agent` less than a
second after startup, with **no** `attested=true` anywhere. The agent did not fail
attestation; it never got that far, because it was told to exit. Confirm it is
simply not running:

```bash
pgrep -fl swa-agent || echo "not running"
```

Two causes, in order of likelihood:

1. **An agent was already running, and you started a second one.** This is by far
   the most common cause, and it is worse than it looks. The new process finds the
   socket path taken and exits immediately — but on the way in it has already
   **deleted the socket** the first agent was serving, and its `>` has **truncated
   the log** that held the first agent's `attested=true` lines. So one mistake
   produces a dead second agent, a first agent nobody can reach, and a log that
   reads exactly like failed attestation. Reproduced verbatim: one bootstrap line,
   a sub-second shutdown, `attested=true` = 0, `Failed to attest` = 0.

   Recover by killing everything and starting once:

   ```bash
   pkill -f "swa-agent run"; sleep 2
   scripts/restart-agent.sh
   ```

2. **The agent was launched without `nohup` and the shell that started it went
   away.** A backgrounded job started with a bare `&` receives `SIGHUP` when its
   terminal closes — including when a `set -e` failure kills the shell (see
   [07](07-troubleshooting.md#sourcing-a-script-closes-your-terminal)). Use the
   `nohup` form given above.

`context cancelled` names the mechanism, not the reason. It always means "someone
cancelled the root context" — a signal — and never a network, certificate, or
configuration problem. In particular, **this is not a trust-bundle problem**; if
there were a certificate mismatch you would see `Failed to attest` with a non-zero
count, not a silent exit.

Check for duplicates before you diagnose anything else:

```bash
pgrep -fl "swa-agent run" | wc -l    # must be 1
```

## Trap: `certificate signed by unknown authority (firefly root)`

```
level=ERROR msg="Failed to attest" subsystem=node-attestator
  error="could not open attestation stream to SPIRE server: rpc error:
  code = DeadlineExceeded ... transport: authentication handshake failed:
  tls: failed to verify certificate: x509: certificate signed by unknown
  authority (possibly because of \"x509: ECDSA verification failure\" while
  trying to verify candidate authority certificate \"firefly root\")"
```

**Cause: the agent is holding a server root CA that the control plane no longer
publishes.** Every time the `swa-server` pod starts it logs:

```
msg="generating self-signed root CA" logger=bootstrap/selfsigned
```

That root is **new each time** — it is not persisted across pod restarts. It is
uploaded to the control plane and added to the trust bundle, which is why
`.well-known/ca-bundles` accumulates roots (`{"n":3}` after three server starts).

**An ordinary `rollout restart` does not break a running agent.** Verified: the
agent kept working across a rolling restart, two back-to-back restarts, and a
`scale 0` → `scale 1` cycle, because the bundle it holds still contains a root that
chains to what the server presents, and it simply reconnects:

```
msg="Connection state changed" state=CONNECTING
msg="Connection state changed" state=READY
msg="New leased connection" attested=true
msg="Skipping re-attestation" attested=true reAttest=false
```

The failure appears when the agent's cached bundle and the server's current chain
have **no root in common**. That happened here after the trust domain was deleted
and recreated — the bundle was emptied and repopulated from scratch, so the root
the agent had cached no longer existed anywhere. See
[07](07-troubleshooting.md#the-jwks-went-empty-after-it-was-working).

Note this is a *server*-CA mismatch and has nothing to do with your `x509pop` agent
certificate, which is unaffected. Do not regenerate agent certificates in response
to this error.

Prove it the way the agent does — verify the chain the server presents against the
bundle the control plane publishes. Do not try to compare fingerprints by eye: the
endpoint returns **base64-encoded DER**, the published roots are several, and
`openssl x509 -fingerprint` prints the fingerprint of the certificate you handed
it, never of its issuer, so a root-vs-intermediate comparison can never match even
when everything is healthy.

```bash
# 1. published roots -> one PEM bundle
curl -sS "${TD_URL}/.well-known/ca-bundles" | python3 -c '
import sys, json, base64, subprocess
pems = []
for b in json.load(sys.stdin)["bundles"]:
    p = subprocess.run(["openssl","x509","-inform","DER","-outform","PEM"],
                       input=base64.b64decode(b), capture_output=True)
    pems.append(p.stdout.decode())
open("/tmp/roots.pem","w").write("".join(pems))
print("published roots:", len(pems))
'

# 2. the chain the server presents, split into leaf + intermediate
openssl s_client -connect 127.0.0.1:8443 -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' > /tmp/chain.pem
awk '/BEGIN CERT/{n++} {print > ("/tmp/e" n ".pem")}' /tmp/chain.pem

# 3. does the leaf chain to anything published?
openssl verify -CAfile /tmp/roots.pem -untrusted /tmp/e2.pem /tmp/e1.pem
```

```
published roots: 7
/tmp/e1.pem: OK
```

(`published roots` counts every server start in this trust domain's history, so
expect a smaller number on a fresh lab.)

`OK` means the trust bundle is fine and your failure is elsewhere. An
`unable to get local issuer certificate` error is the real mismatch. `/tmp/e2.pem`
is the `CN=firefly` intermediate; `/tmp/e1.pem` is the leaf, whose subject is empty
because its identity lives entirely in the SPIFFE URI SAN.

**Fix — restart the agent so it re-fetches the current bundle:**

```bash
pkill -f "swa-agent run"; sleep 2
rm -f /tmp/swa-agent/public/api.sock; mkdir -p /tmp/swa-agent/public
nohup swa-release-v1.0.2/binaries/swa-agent_1.0.0-SNAPSHOT_darwin_arm64/swa-agent \
  run -d agent-config > /tmp/agent.log 2>&1 &
sleep 12
grep -ac "attested=true" /tmp/agent.log     # 5
grep -ac "Failed to attest" /tmp/agent.log  # 0
```

**When to restart the agent:** after anything that resets the trust bundle rather
than adding to it — recreating the trust domain, recreating the server group, or a
`teardown.sh` followed by a rebuild. A plain `rollout restart` does not require it,
but restarting the agent afterwards is harmless and takes 12 seconds, so if you are
unsure, just do it:

```bash
scripts/restart-agent.sh
```

That script does the `pkill` / clear-socket / `nohup` / verify sequence and tells
you which failure you have if it does not come up.

`DeadlineExceeded` in the message is a red herring: the handshake fails and gRPC
retries until the deadline, so the timeout is the symptom, not the cause.

## Trap: `no generator for nodegroup`

If you created the node group *after* the server started, the first SVID fetch
fails:

```
ERROR rpc error: ... failed to get identity for workload: no generator for nodegroup
```

and the server log names the group it cannot serve:

```
msg="Failed to get identity for workload" node-group=macos-unix-ng error="no generator for nodegroup"
```

The agent is attested; the server simply has not synced the new node group. Its
`syncInterval` is **15 minutes**. Rather than wait, restart it:

```bash
kubectl rollout restart deploy/swa-server -n swa-system
kubectl rollout status deploy/swa-server -n swa-system --timeout=180s
kubectl get pods -n swa-system
```

Wait for the new pod to be `1/1 Running`, then re-fetch. **The agent does not need
restarting** — verified: it logs a `CONNECTING` → `READY` transition and keeps its
attestation:

```
msg="Connection state changed" state=CONNECTING
msg="Connection state changed" state=READY
msg="Skipping re-attestation" attested=true reAttest=false
```

If the fetch still fails, restarting the agent is cheap and harmless:

```bash
scripts/restart-agent.sh
```

To avoid this entirely, create node groups **before** installing the server, or
lower `controlPlane.syncInterval`.

---

Next: [05 — Fetch and verify SVIDs](05-fetch-svid.md)
