# 00 — Prerequisites

## Entitlements you need before the workshop

| Requirement | Notes |
|---|---|
| CyberArk Secrets Manager - SaaS tenant | With Secure Workload Access enabled |
| An Identity user with the **Secrets Manager Admin** role | Its password is used for API auth |
| `swa-release-v1.0.2.tgz` | From the Palo Alto Networks Marketplace, under Idira solutions |
| An OpenAI organization where you are **owner** | Owner is required to configure workload identity federation |
| OpenAI account with credits | Needed only for the final inference call; auth works without them |

## Hardware and OS

Written and validated on **macOS 15 (Darwin 25.5.0), Apple Silicon (arm64)**.

Apple Silicon matters in one specific place: the release ships both `amd64` and
`arm64v8` container images, and the reference `.env-template` in the public
`swa-demos` repository defaults to `amd64`. On an M-series Mac you must use
`arm64v8` or the SWA Server pod will crash-loop.

## Tools

```bash
brew install kind helm kubectl jq
```

Podman Desktop (or Docker Desktop) must be installed and its VM running:

```bash
podman machine list      # expect: Currently running
```

Verified versions:

```
kind    v0.32.0
helm    v4.2.3
kubectl v1.36.2
podman  5.8.4
```

`openssl`, `python3`, `curl`, and `awk` ship with macOS. Note that macOS
`openssl` is **LibreSSL**, not OpenSSL — it lacks the `-ext` flag used by many
online examples. Where that matters, these documents use a portable alternative.

### Why kind, and why a pinned version

SWA 1.0.2 supports Kubernetes **1.33–1.35**. Podman Desktop and Docker Desktop
currently bundle Kubernetes **1.36.x**, which is outside that range. So instead
of the bundled Kubernetes, this workshop runs a `kind` cluster on the Podman VM
with the node image pinned:

```yaml
image: kindest/node:v1.35.5
```

Do not remove the pin. Later kind versions default to 1.36+.

## Configuration

Copy the template and fill it in:

```bash
cp .env-template .env
```

```bash
CONJUR_APPLIANCE_URL=https://<subdomain>.secretsmgr.cyberark.cloud/api
IDENTITY_TENANT_URL=https://<tenant>.id.cyberark.cloud
IDSEC_USERNAME=<user>@cyberark.cloud.<NNNN>
IDSEC_SECRET=<that user's password>
SWA_TRUST_DOMAIN=swa-lab.local
```

Two traps here, both of which cost real debugging time — see
[01-authentication.md](01-authentication.md) for the full diagnosis:

1. **`IDENTITY_TENANT_URL` is a different host** from `CONJUR_APPLIANCE_URL`.
   One is `*.id.cyberark.cloud`, the other `*.secretsmgr.cyberark.cloud`.
2. **`IDSEC_SECRET` is a password, not an OAuth client secret.** A short value
   (9 characters, say) is not evidence that it is wrong.

Values must be **unquoted**. Surrounding quotes become part of the value.

Two more variables get appended later, once the OpenAI console has issued them
([06](06-openai-federation.md#3-record-the-two-ids)). Leave them out for now:

```bash
OPENAI_IDENTITY_PROVIDER_ID=idp_...
OPENAI_SERVICE_ACCOUNT_ID=user-...
```

`.env` is gitignored, along with `artifacts/`, `*.key`, `*.crt`, `*.cert`, and
`*.jwt`.

To load it, use `set -a` so the values are **exported**, not merely assigned:

```bash
set -a; source .env; set +a
```

`scripts/swa-auth.sh` does this internally, so sourcing that is equivalent. A
bare `source .env` leaves the scripts unable to see anything.

## Unpack the release

```bash
mkdir -p swa-release-v1.0.2
tar xzf ~/Downloads/swa-release-v1.0.2.tgz -C swa-release-v1.0.2
```

Do not use `tar --one-top-level`; macOS ships **BSD tar**, which has no such
flag.

What is inside, and what is not:

```
swa-release-v1.0.2/
├── binaries/                 # swa-AGENT only, for darwin+linux / amd64+arm64
├── container-images/          # swa-agent AND swa-server, amd64 + arm64v8
├── helm/                     # swa-server-0.1.0.tgz, swa-agent-0.1.0.tgz
├── ansible/                  # reference agent config templates
└── manifest.txt              # release: v1.0.2
```

**There is no SWA Server binary for any platform.** The server runs only as a
container, via Helm. (`SHA256SUMS` lists a `swa-server_*_darwin_arm64.tar.gz`,
but that is a build-wide manifest, not a description of this package — no such
file ships. Do not go looking for it.)

Conversely, a **native macOS `swa-agent` binary does ship**, even though the
published documentation only describes installing agents on Linux VMs via
Ansible. This workshop uses that native binary, which is what makes a
container-free agent possible.

## Verify the agent binary runs

```bash
cd swa-release-v1.0.2/binaries/swa-agent_1.0.0-SNAPSHOT_darwin_arm64
xattr -d com.apple.quarantine swa-agent    # REQUIRED — see below
chmod +x swa-agent
./swa-agent version
```

```
1.0.0-SNAPSHOT
```

**Do not skip the `xattr` step.** The binary is code-signed by CyberArk but
**not notarized**, so Gatekeeper kills it on first execution — silently.
The failure mode is genuinely misleading:

```
$ ./swa-agent version
$ echo $?
137
```

No error message. No dialog. Exit code 137 is SIGKILL. Diagnosis:

```bash
codesign -dv swa-agent    # signed: CYBERARK SOFTWARE INC. (Y6C5PMT6J8)
spctl -a -vv swa-agent    # rejected, source=Unnotarized Developer ID
```

Attendees on managed laptops with strict Gatekeeper policies may be unable to
clear the quarantine flag at all. Establish this before the workshop starts.

---

Next: [01 — Authentication](01-authentication.md)
