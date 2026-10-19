# SIM remote fleet

Node 24 services and terminal client for the remote execution layer. The Mac
application retains FIDO signing and PIV unwrap. No npm dependencies are required.

Each task gets a mountless sbx microVM. Inside it, the agent runs as UID 0 in a
rootless Podman container owned by guest UID 2000. A finite ext4 filesystem bounds
container writes; cgroup v2 bounds CPU, memory and PIDs. Guest root owns the
firewall, the process observer and the evidence stream outside the container.

## Implementation status

Experimental implementation: delivered for review and target-host qualification.
No cloud resources were provisioned and 200-agent capacity has not been measured.

The repository includes the controller, SQLite task/lease store, Google identity
verification, FIDO grant verification, encrypted source/results, rootless guest
launcher, streaming evidence, model gateway, GCP host provider, independent reaper,
OpenTofu infrastructure and signed release packaging. The CLI includes plan,
authorize, create, tasks, hosts, logs, attach, fetch, diff, import and revocation.

The automated suite runs against real SQLite, HTTP, TCP proxying, cryptography,
subprocesses and the Python guest archive parser.
It does not qualify real KVM/sbx/Podman, a hardware token, provider model access, or
a GCP deployment. Run the target-host checks below before accepting production
work. In particular, Docker's supported authentication for a newly created
headless host must be established; there is no bypass or baked-in Docker login.

## Trust and credential handling

- All control traffic uses TLS and verified Google identity tokens. Workers have
  their own attached GCP service account with no provisioning authority.
- A fleet grant binds the exact policy, source digests, worker/template digests
  through the policy digest, broker recipient, model, argv and resource/spend/time
  limits. The grant is signed with the same OpenSSH FIDO key pinned into SIM.
- Nonces are single use and tied to the authenticated owner. SQLite consumes
  nonces and cumulative task allowances transactionally.
- Source is encrypted locally before upload. Its random AES key is wrapped to
  your public PIV certificate for recovery and to the controller's ephemeral
  X25519 key for this session. Broker restarts require a new signed unlock.
- Provider credentials stay in the separate gateway. Agents get a per-task
  capability bounded by model, request count, lease, expiry and output tokens.
  Revocation stops new requests; an already streaming provider request may finish.
- Package traffic uses an authenticated HTTPS CONNECT proxy on the gateway.
  Only reviewed `egress_hosts` authorities on port 443 are accepted. DNS answers
  must be public IPv4 addresses, and the proxy dials the checked address directly.
  Concurrent sessions, absolute lease deadlines and transactional task byte
  reservations bound this delegated network access.
- Evidence and candidates are encrypted with domain-separated AES-GCM records.
  The independent collector writes immutable content-addressed GCS objects with
  create-only permissions. Cloud IAM and retained storage remain owner-controlled.
- No SSH-agent, USB, PIV private key, real repository .git directory, or host
  management socket enters the worker container.

The cloud host and trusted services can read running plaintext; this is not
confidential computing. A hardware signature authorizes bounded delegation,
not continuous hardware presence. The model gateway enforces request/output
limits, not an exact dollar ceiling. Compute budgets are estimates and exclude
disks, inference, logging, networking and trusted services. Concurrent grants
reserve their full authorized compute amounts against `max_fleet_micros`.

CONNECT is opaque: the proxy cannot inspect the tunneled TLS SNI or HTTP host.
An allowed shared CDN IP may serve other origins through domain fronting. Treat
this as bounded access to reviewed network endpoints, not origin isolation or
DLP. For strict separation, use your own single-tenant package mirrors and an
explicit narrow allowlist; use an empty list for offline work. Model prompts
also intentionally reach the authorized provider.

Network credit is reserved in 16 MiB blocks, including both tunnel directions;
unused credit is not refunded. The default task allowance is 2 GiB. Each task
has at most eight live proxy sessions, bounded by its current lease and a
120-second maximum. A revocation stops additional credit; a tunnel may consume
its existing reserved credit until its deadline. Repository redirects require
the redirected authority to be allowlisted too. Use HTTPS package URLs: plain
HTTP forward-proxy requests are rejected. The Debian worker image converts its
APT sources to HTTPS. Qualify the selected apt/npm/pip/cargo versions with the
HTTPS authenticated proxy before relying on dependency installation.

The encrypted artifact cache is capped at 32 GiB and 4,096 objects. Export and
retain desired results before owner-managed pruning; a full cache rejects new
uploads. Audit storage has a separate retention policy. Candidate export uses
the original source's ignore rules and preserves original tracked-but-ignored
files. New symlinks and special files are rejected.

## Build and inspect

```bash
node --version                 # v24.x
make check
./scripts/check               # requires Swift 6
```

Build the Mac release through the existing signed/notarized release workflow.
It embeds the fleet client in the sealed app. `sim fleet sign` only signs through
the existing pinned FIDO gate. `sim fleet unwrap-key` only accepts the configured
hardware PIV certificate and returns a key to the local client through a pipe.

For development, run `node fleet/bin/sim-fleet.mjs help`. Live signing still uses
the installed SIM; this does not add a software-key fallback.

## Prepare immutable runtime images

Build `deploy/Worker.Containerfile` with an immutable Node 24 base image and
explicit Claude/Codex package versions:

```bash
podman build -f fleet/deploy/Worker.Containerfile \
  --build-arg NODE_BASE=REGISTRY/NODE_IMAGE@sha256:VERIFIED_DIGEST \
  --build-arg CODEX_VERSION=YOUR_QUALIFIED_VERSION \
  --build-arg CLAUDE_VERSION=YOUR_QUALIFIED_VERSION -t sim-worker:build .
podman save --format docker-archive -o worker-image.tar sim-worker:build
sha256sum worker-image.tar
```

Publish the worker image to your chosen registry and record its immutable OCI
digest. The archive loaded into Podman must retain that digest-addressable image
reference. Verify `podman image exists REGISTRY/IMAGE@sha256:DIGEST` inside the
prepared guest; an archive with only an unrelated local tag does not qualify.

In an empty Linux sbx builder VM, run `deploy/prepare-guest` as guest root with
the verified worker archive, its SHA-256, and the public fleet CA. It installs
Podman, uidmap, pasta, nftables, strace and filesystem tooling and provisions
simworker with subordinate UID/GID ranges. Save/stake this credential-free
template through SIM. Publish and pin its x86-64 sbx image digest.

Make a release directory with `deploy/package NEW_DIRECTORY FIDO_KEY_PATH`.
The packaging command prints the release SHA-256 and obtains a hardware signature.
Review the release manifest with your pinned public key before executing it.

Build two immutable Ubuntu 24.04 GCP images with `deploy/install-host`: one
`trusted` and one `worker`. Supply the signed release directory, expected release
digest, pinned FIDO public key, a verified official Node 24 Linux archive and its
SHA-256, and the approved Docker sbx Debian package and its SHA-256. These are
operator-supplied inputs; no `curl | sh` or unpinned installer is used. The worker
image must also have its qualified sbx template available. Publish immutable GCP
image names; image families are rejected by the infrastructure module.

Golden images contain code and public certificates only. Docker account
enrollment, cloud credentials and TLS private keys must not be captured in them.

## Bootstrap GCP from the terminal

1. Authenticate with your own hardware-protected Google account using
   `gcloud auth login`. Set the intended project explicitly. Prepare your
   owner account's numeric Google subject ID and the public audience in its
   `gcloud auth print-identity-token` token. Decode those locally; never paste
   the token into a third-party decoder. OS Login security-key enrollment is a
   separate Google-account step from SIM's existing FIDO signing key.
2. Run `fleet/deploy/tls-init NEW_PRIVATE_DIRECTORY`. It produces a public CA
   certificate and a private JSON payload for each trusted service. Keep the CA
   private key offline. Server certificates include the fixed private IP and
   localhost for IAP-forwarded access and expire after 90 days. Rotate them
   before expiry; restart the corresponding service after uploading a new version.
3. Supply the declared variables in `fleet/infra/gcp/variables.tf`, including
   immutable GCP images, OCI digests, FIDO public key, owner identity, model
   allowlists, exact GitHub workflow identity and a dated regional cost estimate.
   Use an ignored local tfvars file. Never put private keys or bearer tokens in it.
4. Run `tofu -chdir=fleet/infra/gcp init` and then
   `tofu -chdir=fleet/infra/gcp plan -out=stack.tfplan`. Review and apply the saved
   plan as owner. The module creates no worker instances until a grant is active.
5. Upload the three locally generated service JSON payloads to the respective
   Secret Manager secrets returned by `tofu output -json tls_secrets`, using
   `gcloud secrets versions add SECRET_ID --data-file=SERVICE.json`. Restart
   each trusted service after its first secret version is available. The
   `ExecStartPre` bootstrap retries with the role's attached identity until a
   valid secret exists and fetches the latest version on restart. Empty secrets
   prevent an insecure TLS fallback. Terraform never handles secret versions.
6. Save `tofu -chdir=fleet/infra/gcp output -raw fleet_policy > fleet-policy.json`.
   Match the downloaded policy against the reviewed deployment. The policy is
   public authorization configuration, not a credential.

The controller, gateway, collector and reaper have private addresses. IAP permits
SSH only from Google's IAP range. Worker-to-worker access is absent. A separate
timer-driven VM reaps expired worker hosts even if the controller fails. Retained
audit objects and trusted state disks are protected from ordinary teardown.

The GitHub federation provider is bound to numeric repository/owner IDs, exact
workflow identity and main. The created deployment identity initially has no
infrastructure mutation grants. Connect it to your existing reviewed deployment
pipeline with the narrowly scoped publishing permissions that pipeline needs;
this module does not grant a CI workflow unrestricted IAM administration.

## Connect and authorize work

Open a hardware-key SSH tunnel from the Mac. Replace the project/zone/name with
the values from your deployment:

```bash
gcloud beta compute ssh sim-fleet-controller \
  --project YOUR_PROJECT --zone us-central1-a --tunnel-through-iap \
  -- -N -L 7660:127.0.0.1:7660
```

The CLI validates the localhost service certificate against the public fleet CA.
Keep the tunnel in its own terminal. Every live command uses the same common
arguments; a shell alias can hold these public paths:

```bash
sim fleet plan --config fleet-policy.json --count 200 --profile light \
  --seconds 3600 --budget-micros 50000000

sim fleet authorize --config fleet-policy.json --ca ca.crt \
  --connect https://127.0.0.1:7660 --repo "$PWD" --owner-cert YOUR_PUBLIC_PIV_CERT.pem \
  --vendor codex --model YOUR_ALLOWED_MODEL --count 200 --profile light \
  --seconds 3600 --budget-micros 50000000 -- exec --dangerously-bypass-approvals-and-sandbox 'Perform the requested task'

sim remote create --config fleet-policy.json --ca ca.crt \
  --connect https://127.0.0.1:7660 --grant GRANT_ID --count 200
```

The authorization command copies tracked and nonignored files, rejects common
credential filenames and symlinks, encrypts the snapshot, displays the exact
grant, and obtains a FIDO signature. It saves only ciphertext, signed metadata
and a PIV-wrapped recovery key under `/usr/local/var/agent/fleet`. Normal SIM local
installation must make that state directory accessible to its owner.

Use `tasks`, `hosts` and `reconcile` through `sim fleet`, and `attach TASK_ID`,
`logs TASK_ID`, `fetch TASK_ID --out NEW_DIRECTORY`, `diff TASK_ID` and
`import TASK_ID --repo LOCAL_REPO` through `sim remote`. Append the common
configuration/CA/connection arguments to each command. Fetch/diff/import/log
decryption invokes the local PIV operation. Import requires a clean host tree and
index, displays and signs the exact patch transaction, then applies a full-index binary
patch against an exact baseline. It verifies both raw files and indexed objects
against the authorized candidate. Automatic three-way merging is unsupported;
no automatic commit or push occurs. Attribute-file transactions and active
working-tree conversions (including ident, EOL and encoding) are rejected before
mutation. Binary patch transport preserves arbitrary non-UTF-8 file content. Remote import ignores global/system Git configuration and refuses local
Git filter configuration (including included configuration) before each host Git
operation. Repositories requiring filters such as Git LFS must use a separate,
explicitly reviewed import workflow. Review patches retain raw file bytes rather
than candidate-selected EOL, encoding, or clean-filter normalization.
Existing local SIM import behavior is unchanged.

Use `sim fleet revoke --grant GRANT_ID` to cancel tasks and retire that grant's
hosts, `pause` to stop dispatch and scale-out, and `resume` to resume dispatch.
Each control operation obtains a fresh challenge and hardware signature.
After a controller restart, `unlock --grant GRANT_ID` restores only that grant's
ephemeral decryption authority through your PIV token and another signed grant.

## Model configuration

Configure OpenAI Platform workload identity federation for the gateway's attached
Google service account. Put its provider and service-account mapping IDs in the
gateway service configuration. The gateway obtains Google OIDC tokens and
exchanges them at the documented OpenAI token endpoint. Codex native ChatGPT
workspace federation is a separate managed-workspace beta and is not required.

Claude messages use GCP Vertex rawPredict/streamRawPredict with an attached
identity; token counting uses Vertex's `count-tokens:rawPredict` route and beta
headers are forwarded. The adapter follows the [official Anthropic Vertex SDK](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/packages/vertex-sdk/src/client.ts). A native Anthropic API key, or
an OpenAI API key when federation is unavailable, can be supplied via an owner-
managed private gateway file. Such credentials are never sent to worker hosts.

## Target-host acceptance

Before enabling production work, prove all of the following on a real host:

- The selected N2 zone exposes usable KVM and sbx creates a real nested microVM.
- Fresh-host Docker enrollment and refresh work with the intended headless
  lifecycle. A manual login per autoscaled host is not unattended scale-out.
- The guest template supports cgroup v2 delegation, rootless Podman, pasta,
  loopback ext4 mounting and guest-root ptrace. Failed checks prevent release.
- The worker's pinned OCI digest exists after archive load. It sees UID 0 while
  the guest sees UID 2000. Package management works within its filesystem quota.
- Metadata, peer guests, management sockets and observer evidence are inaccessible.
- Both provider CLIs stream successfully, use the allowed model, receive
  cancellation/revocation and respect quotas. The private CA must be trusted
  by both CLIs; it is installed during guest setup. Codex is explicitly routed
  to the signed model through a custom Responses provider; websocket transport
  is disabled. For autonomous root execution use the bypass flag shown above
  inside the isolated container. Claude can receive an explicit signed
  `--allowedTools` list (for example `Bash,Read,Write,Edit,Glob,Grep`) and a print
  prompt; tool permission and root behavior must be qualified for its version.
- Killing the observer or losing audit upload terminates execution. Evidence
  remains in retained storage after guest deletion.
- Controller and host restarts fence stale leases. Lost tasks are reported as
  lost rather than automatically repeated with uncontrolled external effects.
- Confirm regional N2 vCPU/SSD quotas (the light 200-agent estimate needs
  128 N2 vCPUs), plus provider RPM/TPM allowances. The gateway admits up to
  256 model requests, two per task, with 4 MiB request bodies; excess requests
  receive a retryable 429. Its configured VM has 16 GiB memory.
- Run 1, 2, 20, 50 and then 200 tasks, with full audit, recording actual density,
  disk/trace growth, startup latency and the complete cloud bill.

Worker compute can reach zero after the idle grace period. Trusted services,
state disks, NAT and retained artifacts still cost money. Always-on 200-agent
operation should be compared with a dedicated bare-metal pool before purchase.
