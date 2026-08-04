# 03 — SWA Server on kind

The SWA Server is the component that attests agents and mints SVIDs. It ships
only as a container image, so it needs Kubernetes — but a single-node `kind`
cluster on the Podman VM is enough.

Order matters here. The server group must exist before the server is registered,
and the server must be *running* before the node group is created.

## 1. Generate the x509pop CA

The macOS agent will prove its identity with a certificate. This CA signs it.

```bash
mkdir -p artifacts
openssl genrsa -out artifacts/ca.key 4096
openssl req -new -x509 -days 3650 -key artifacts/ca.key \
  -out artifacts/ca.crt -subj "/CN=SWA Node Attestation CA"
```

Any certificate signed by this CA can attest as a node, so in production use a
dedicated intermediate CA rather than an organizational root. `artifacts/` is
gitignored.

## 2. Create the server group

The server group holds the CA bundle used to validate agent certificates.

```bash
source scripts/swa-auth.sh

jq -nc --rawfile pem artifacts/ca.crt \
  '{name:"macos-lab",
    description:"macOS native agent server group (x509pop)",
    node_attestation:{x509pop:{ca_certificates:$pem}}}' > /tmp/sg-body.json

scripts/swa-api.sh POST \
  /api/swa/trust-domains/swa-lab.local/server-groups "$(cat /tmp/sg-body.json)"
```

```
HTTP 201
```

### Trap: the documented PEM recipe corrupts the certificate

CyberArk's documentation builds the PEM payload like this:

```bash
# Correct ONLY for direct shell interpolation into a JSON string
export CA_CERT_PEM=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' ca.crt)
```

That emits a *literal backslash-n* on purpose, for splicing straight into a JSON
document. Combine it with `jq --arg` — the natural way to build JSON safely —
and `jq` escapes the backslash again. The stored certificate then contains
`\\n` instead of newlines:

```
"-----BEGIN CERTIFICATE-----\\nMIIEwDCCAqgCCQCMPZhnzg5x+jANBgkqhkiG9w0BAQsFADAiMSAwHgYDVQQDDBdT\\n...
```

The API accepts it with HTTP 201. Nothing fails until agent attestation, at which
point the CA cannot be parsed and the error points nowhere near the cause.

Use `jq --rawfile`, which reads the file with real newlines and encodes them
correctly. Verify the round trip rather than trusting it:

```bash
scripts/swa-api.sh GET /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab \
  | jq -r '.node_attestation.x509pop.ca_certificates' \
  | openssl x509 -noout -subject
```

```
subject= /CN=SWA Node Attestation CA
```

If that command errors, the stored PEM is corrupt. Delete the server group and
recreate it:

```bash
scripts/swa-api.sh DELETE /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab
```

## 3. Create the kind cluster

`kind-cluster.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: swa-lab
nodes:
  - role: control-plane
    image: kindest/node:v1.35.5
    extraPortMappings:
      - containerPort: 30443
        hostPort: 8443
        listenAddress: "127.0.0.1"
        protocol: TCP
```

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --config kind-cluster.yaml
```

Takes about 26 seconds. The port mapping publishes the server's API on
`127.0.0.1:8443`, where the native macOS agent can reach it.

```bash
kubectl wait --for=condition=Ready node/swa-lab-control-plane --timeout=120s
```

## 4. Load the server image

**On Apple Silicon, use `arm64v8`:**

```bash
kind load image-archive --name swa-lab \
  swa-release-v1.0.2/container-images/swa-server-1.0.0-SNAPSHOT-arm64v8.tar
```

Verify — this command is silent on success, so check explicitly:

```bash
podman exec swa-lab-control-plane crictl images | grep swa
```

```
docker.io/library/swa-server   1.0.0-SNAPSHOT-arm64v8   322a05f9fe78e   20.9MB
```

## 5. Register the server

The server authenticates to the SaaS control plane using its Kubernetes service
account token. CyberArk therefore needs to validate that token, which means it
needs the cluster's public keys.

```bash
kubectl get --raw '/.well-known/openid-configuration' | jq -c '{issuer, jwks_uri}'
```

```json
{"issuer":"https://kubernetes.default.svc.cluster.local","jwks_uri":"https://10.89.2.2:6443/openid/v1/jwks"}
```

Both are unreachable from the internet — an internal service name and a private
IP. So the `jwks_uri` path is out, and the **`public_keys`** path is required:
fetch the JWKS locally and register it inline.

```bash
kubectl get --raw '/openid/v1/jwks' > /tmp/k8s-jwks.json

jq -n --slurpfile jwks /tmp/k8s-jwks.json '{
  name: "swa-server-macos-lab",
  authentication: {
    type: "JWT",
    data: {
      sub: "system:serviceaccount:swa-system:swa-server",
      issuer: "https://kubernetes.default.svc.cluster.local",
      audience: "conjur",
      public_keys: { type: "jwks", value: { keys: $jwks[0].keys } }
    }
  }
}' > /tmp/reg-server.json

scripts/swa-api.sh POST \
  /api/swa/trust-domains/swa-lab.local/server-groups/macos-lab/components \
  "$(cat /tmp/reg-server.json)" > /tmp/comp.json
```

```
HTTP 201
```

**Capture `authn_id` from the response** — the Helm install needs it:

```bash
AUTHN_ID=$(jq -r '.authn_id' /tmp/comp.json)
```

`audience: conjur` is required; it must match the `aud` claim on the projected
service account token the chart mounts.

## 6. Install with Helm

```bash
mkdir -p /tmp/chart && tar xzf swa-release-v1.0.2/helm/swa-server-0.1.0.tgz -C /tmp/chart

helm install swa-server /tmp/chart/swa-server \
  --namespace swa-system --create-namespace \
  --set controlPlane.url=https://apj-secrets.secretsmgr.cyberark.cloud \
  --set controlPlane.auth.authnID="${AUTHN_ID}" \
  --set rbac.createTokenReviewRole=true \
  --set trustDomain.name=swa-lab.local \
  --set service.type=NodePort \
  --set image.repository=docker.io/library/swa-server \
  --set image.tag=1.0.0-SNAPSHOT-arm64v8 \
  --set image.pullPolicy=IfNotPresent \
  --wait --timeout 180s
```

`controlPlane.url` takes the tenant host **without** the `/api` suffix.
`pullPolicy=IfNotPresent` is essential — the default would try to pull from
Docker Hub and fail, since the image only exists inside the kind node.

**Set `service.type=NodePort` here, in Helm** — not later with `kubectl patch`.
The chart defaults to `ClusterIP`, and patching `spec.type` afterwards makes the
field owned by `kubectl-patch`, so any future `helm upgrade` fails:

```
Error: UPGRADE FAILED: conflict occurred while applying object
swa-system/swa-server /v1, Kind=Service: Apply failed with 1 conflict:
conflict with "kubectl-patch" using v1: .spec.type
```

That matters because recovering from several problems in
[07](07-troubleshooting.md) requires a `helm upgrade`.

```bash
kubectl get pods -n swa-system
```

```
NAME                          READY   STATUS    RESTARTS   AGE
swa-server-849575889c-dbw8f   1/1     Running   0          18s
```

## 7. Confirm the server joined the control plane

```bash
kubectl logs -n swa-system deploy/swa-server --tail=40
```

The four lines that matter:

```
msg="generating self-signed root CA" logger=bootstrap/selfsigned
msg=ServerCaBundleUploaded ... operation=UploadServerCaBundle
msg=SVIDIssued ... svid-type=X509 subject=spiffe://swa-lab.local/server
msg=KeyUploaded ... operation=UploadSigningKey kid=da245440-b30a-4c29-9042-47d5c44682ce
```

The server minted its own identity and uploaded its signing key. The trust
domain's JWKS is now populated:

```bash
curl -sS "${TD_URL}/.well-known/jwks" \
  | jq -c '{n:(.keys|length), algs:[.keys[].alg]}'
```

(`TD_URL` comes from
[02](02-trust-domain.md#set-td_url-once) — re-derive it if this is a new shell.)

```json
{"n":1,"algs":["RS512"]}
```

An RS512 public key is now published on the internet. OpenAI will fetch it from
here.

Expect `n` to grow. The server generates a new signing key each time it starts,
and old public keys stay published until their `signing_key_ttl` (24h) expires —
so after a `rollout restart` you will see `{"n":2,...}`. That is correct
behaviour, not a leak: it lets tokens signed by the previous key keep validating
until they expire. Relying parties select by `kid`.

The line above it in the log behaves the same way:

```
msg="generating self-signed root CA" logger=bootstrap/selfsigned
```

The server's **root CA is also new on every start** and is *not* persisted across
pod restarts — but it is uploaded to the control plane, and
`.well-known/ca-bundles` **accumulates** roots rather than replacing them:

```bash
curl -sS "${TD_URL}/.well-known/ca-bundles" | jq -c '{n:(.bundles|length)}'
```

```json
{"n":3}
```

`n` equals the number of times a server has started in this trust domain, so it is
`1` on a fresh lab and climbs from there. So a running agent, which caches the
bundle at startup, still holds a root that the
restarted server chains to. **A `rollout restart` does not break a running agent** —
verified across a rolling restart, two back-to-back restarts, a `scale 0`/`scale 1`
cycle, and a 90-second outage. The agent reconnects and keeps its attestation. What
*does* orphan an agent is a bundle **reset** — deleting and recreating the trust
domain or server group. See
[04](04-macos-agent.md#trap-certificate-signed-by-unknown-authority-firefly-root).

## 8. Pin the nodePort to 30443

The service is already `NodePort` from step 6, but Kubernetes assigned a *random*
port in the 30000–32767 range. `kind-cluster.yaml` maps host `8443` to container
`30443` specifically, so the API port must be pinned:

```bash
kubectl get svc swa-server -n swa-system -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
```

If that is not `30443`, patch **only the nodePort** — never `spec.type`:

```bash
kubectl patch svc swa-server -n swa-system --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30443}]'
```

A JSON-patch on a single leaf field does not take ownership of `spec.type`, so
`helm upgrade` keeps working. Verified: after this patch, a subsequent
`helm upgrade` succeeds and the nodePort stays `30443`.

Confirm the host can reach it:

```bash
kubectl get svc swa-server -n swa-system --no-headers
nc -z 127.0.0.1 8443 && echo reachable
```

```
swa-server   NodePort   10.96.45.238   <none>   8443:30443/TCP,8080:31117/TCP   3h26m
reachable
```

The `web` port's nodePort is irrelevant — nothing maps it.

## 9. Inspect the server certificate

This was the design's biggest unknown: the chart has no SAN or `dnsNames`
setting, so which hostname must the agent use?

```bash
openssl s_client -connect 127.0.0.1:8443 -showcerts </dev/null 2>/dev/null > /tmp/s.out
awk '/BEGIN CERT/,/END CERT/' /tmp/s.out > /tmp/chain.pem
awk '/BEGIN CERT/{n++} {print > ("/tmp/c" n ".pem")}' /tmp/chain.pem
openssl x509 -in /tmp/c1.pem -noout -text | grep -A2 "Subject Alternative Name"
```

```
X509v3 Subject Alternative Name: critical
    DNS:server.swa-lab.local, URI:spiffe://swa-lab.local/server
```

The server generates its own cert with SANs `server.<trust-domain>` and its
SPIFFE URI. (macOS `openssl` is LibreSSL and rejects `-ext`; the `-text | grep`
form above works on both.)

**But the DNS name turns out not to matter.** SPIFFE mTLS validates the SPIFFE
URI SAN, not the hostname, so the agent connects happily to `127.0.0.1:8443`.
This was verified by running the agent against the raw loopback address —
attestation succeeded. No `/etc/hosts` entry, and therefore **no `sudo`**, is
required anywhere in this workshop.

If you prefer the hostname form for realism, add the alias — but it is optional:

```bash
echo '127.0.0.1 server.swa-lab.local' | sudo tee -a /etc/hosts
```

---

Next: [04 — macOS agent](04-macos-agent.md)
