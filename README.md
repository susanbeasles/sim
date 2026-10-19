# Sim

`sim` is a native Swift controller for running Claude Code and Codex inside mountless Docker Sandboxes while keeping the real host repository outside the agent trust boundary.

The daily path is intentionally simple:

```zsh
alias cc='sim claude'
alias codex='sim codex'

cd ~/code/backup-control
cc
```

The vendor TUI runs inside the disposable VM. The host repository is copied in, never mounted read-write.

## v0.2.0: hardware-rooted staked images

v0.2 adds a cryptographic image lineage for trusted VM baselines:

```bash
sim stake -t 'root baseline'
# FIDO/YubiKey touch signs the exact stake manifest

sim image ls
sim image verify 0

sim create --repo backup-control -i 0
# YubiKey PIV private-key operation unwraps the image key
```

A stake consists of:

- a Docker Sandbox template export;
- AES-256-GCM encrypted image bytes in a content-addressed local vault;
- a random 256-bit data-encryption key wrapped to a hardware-backed PIV RSA certificate with RSA-OAEP-SHA256;
- a canonical manifest containing the plaintext/ciphertext digests, generation, immutable tag, repo/vendor/template metadata, audit heads, and parent manifest digest;
- an OpenSSH FIDO (`sk-*`) signature over that exact manifest.

The YubiKey does not decrypt the multi-gigabyte image itself. It unwraps only the 32-byte data key; the Mac streams the image through AES-GCM.

The restore path fails closed:

1. resolve an explicit signed image record;
2. verify every signed manifest back to generation 0;
3. verify the parent digest chain is contiguous;
4. verify ciphertext SHA-256 before touching the private PIV key;
5. perform the YubiKey PIV unwrap;
6. decrypt locally;
7. verify the signed plaintext SHA-256;
8. evict any pre-existing Docker template with the same tag;
9. load only the just-verified tar and create the sandbox from it.

`index.json` is a cache, not authority. Discovery is rebuilt from manifest/signature files. Stake tags are immutable per repository and generations are unique and contiguous.

The temporary plaintext stake template created by `sbx template save` is removed immediately after the encrypted export is produced. During restore, the loaded stake template is removed again after sandbox creation. A restored workspace still gets its own local baseline template for ordinary `agent reset`; reconstructing the vaulted origin is done with `sim create -i ...` in this release.

## Hardware-only key policy

Protected control-plane signing accepts only OpenSSH FIDO/security-key public key types:

```text
sk-ssh-ed25519@openssh.com
sk-ecdsa-sha2-nistp256@openssh.com
```

Release builds pin that public-key SHA-256 fingerprint into the signed `Sim.app`. A plain software SSH private key is rejected.

Vault decryption accepts only a Keychain identity whose private key reports `kSecAttrTokenID`, which macOS uses to identify an external cryptographic store. Software Keychain identities are ignored. The selected identity must also support RSA-OAEP-SHA256 decrypt; `sim key identities` prints `vault-ok` only for compatible hardware identities.

The same physical YubiKey can therefore serve two separate purposes:

```text
FIDO / ed25519-sk     sign stake and protected transaction manifests
PIV RSA key           unwrap each staked image's random AES key
```

No PIV slot is created, overwritten, or provisioned automatically. If `sim key identities` shows no `vault-ok` identity, stop there and inspect the YubiKey first.

## Core invariants

- `/usr/local/bin/sim` points into a Developer ID signed, hardened, notarized `Sim.app` under `/usr/local/libexec/sim`.
- Release builds verify their own seal, identifier, Team ID, and signing requirement before doing work.
- Controller state lives under `/usr/local/var/agent`; configuration lives under `/usr/local/etc/agent`. Nothing uses `$HOME/.local`.
- Source lives under `~/code` on the host and `$HOME/code` inside the VM.
- `.git` is not copied from the host. The VM gets a synthetic repository.
- Only `sim git ...` intentionally mutates the host repository.
- `sim git merge`, `sim git commit`, `sim net allow`, and `sim stake` cross protected boundaries and require exact transaction signing.
- Full audit runs the vendor as fake root inside a child user namespace while a real-VM-root supervisor records PTY/syscall evidence outside that namespace.
- There is no controller-imposed maximum workspace/worker count.

## Build and install

On the Mac that owns the Developer ID identity:

```bash
./scripts/init-usr-local
./scripts/check
cp config/release.env.example config/release.env
```

Set the release identity and pin the FIDO key fingerprint:

```bash
ssh-keygen -lf ~/.ssh/id_yubikey.pub -E sha256
```

Put the resulting `SHA256:...` value in `AGENT_AUTH_KEY_FINGERPRINT`, then:

```bash
./scripts/setup-notary agent-notary YOUR_APPLE_ID YOUR_TEAM_ID
./scripts/release
```

`release` performs a clean release build, Developer ID signing, strict verification, notarization, stapling, Gatekeeper assessment, staged install, and installed self-check. A failed install rolls back to the prior `Sim.app`.

After installation:

```bash
sim config auth-key ~/.ssh/id_yubikey
sim key identities
sim config piv-cert <64-hex-certificate-sha256>
sim doctor
```

`sim config piv-cert` refuses a software identity and refuses a hardware identity that cannot perform the required RSA-OAEP-SHA256 unwrap.

## Workspaces

Create from host source:

```bash
sim create --repo backup-control --vendor cc --state clean
sim create --repo backup-control --vendor gpt --state local
```

A bare repo name resolves under `~/code`. `clean` uses the selected committed branch. `local` includes current tracked changes plus nonignored untracked source and cannot be combined with a different branch.

Context repos are copied read-only from the controller's point of view and never become import targets:

```bash
sim create --repo backup-control --vendor cc \
  --context workflows \
  --context sonarmd-logger
```

Lifecycle:

```bash
agent up
agent down
agent reset
agent save --name deps-ready
agent shell
```

`down` preserves the VM filesystem. `reset` restores the workspace's local baseline template. `save` is an ordinary local Docker Sandbox template; it is not the same thing as a cryptographic stake.

## Stake and restore

Create an immutable-name stake from the active workspace:

```bash
sim stake -t 'root baseline'
# alias: agent pew -t 'root baseline'
```

Inspect and verify:

```bash
sim image ls
sim image verify 0
sim image verify 0 --deep   # also performs PIV unwrap + plaintext verification
```

Restore exact generation 0:

```bash
sim create --repo backup-control -i 0
```

You may also select by immutable tag or stake UUID:

```bash
sim create --repo backup-control -i 'root baseline'
sim create --repo backup-control -i 7f2a7c5d-....
```

`--image` cannot be combined with `--branch`, `--state`, or `--context`: the image already defines those bytes and metadata.

Before staking, the guest is scanned for obvious credential files such as AWS/GCP/rclone auth, `.netrc`, `.npmrc`, Codex/Claude credentials, and private `~/.ssh/id_*` files. A hit aborts the stake rather than baking the credential into a recoverable image.

## Review and host Git boundary

Read-only inspection:

```bash
agent diff
agent review
```

Review export is bounded on the host before any guest files are written:

| Resource | Limit |
| --- | --- |
| Archive and combined captured stdout/stderr | 64 MiB per command |
| Regular file | 16 MiB |
| Candidate or baseline tree | 32 MiB each |
| Files and directories, including implicit parents | 10,000 per tree |
| Path depth | 32 components |
| Captured command or extraction | 120 seconds per stage |
| Free disk space before export and during extraction | 1 GiB reserve plus 384 MiB working allowance |

Export accepts regular files and directories in uncompressed USTAR with UTF-8 paths.
Links, special files, sparse archive extensions, unsafe paths, and unsupported archive
formats are rejected. Sparse regular files are charged by logical size. Candidates
that exceed these limits must be reduced before review. Failed exports are removed;
a forced controller termination can leave a bounded export that the next review removes.
The synthetic review repository uses isolated Git configuration so host filters and
hooks cannot amplify guest content. Candidate attributes cannot normalize reviewed
bytes. Imports capture indexed bytes and executable modes before authorization,
bind those snapshots into the signed transaction, and use anchored filesystem
operations that refuse intermediate host symlinks. Host Git operations refuse
configured filters, including included configuration; normal commit-signing
requirements remain in effect. Filter-dependent repositories require a separate,
explicitly reviewed import workflow.

Import all candidate paths:

```bash
sim git merge --theirs
```

3-way merge against the exact copied baseline:

```bash
sim git merge
```

Keep host versions:

```bash
sim git merge --mine
```

Selected paths:

```bash
sim git merge --theirs -- src/a.ts src/b.ts
```

Paths must follow `--`. Extra arguments before the delimiter, an empty path
selection, unknown flags, and conflicting `--mine`/`--theirs` flags are rejected
before opening the workspace. Omitting the delimiter selects all changed paths.
Before authorization, imports display the resolved paths and their signed digest.

Create exactly one local commit from a clean host working tree:

```bash
sim git commit -m 'Implement the thing'
```

`sim git pull` remains reserved in v0.2.0 rather than performing a hidden overwrite.

## Audit

```bash
agent logs
agent logs -f
sim audit sessions
sim audit actions -n 250
sim audit actions --grep 'assets/logo.png'
sim audit verify
sim audit export WORKSPACE -o ~/Desktop/agent-audit
```

Full audit records the local PTY stream plus process/syscall activity and a hash-chained guest head. It does not claim to decrypt vendor HTTPS.

## Remote vault topology

The intended provider topology is fixed as:

```text
                      normal restore bytes
                              |
                              v
                        Cloudflare R2
                              ^
                              |
                 replication / published copy
                              |
                            GCP
                    authoritative write/anchor
                         /            \
                        v              v
                      R2              B2
                                  retained replica

Dropbox sync/backup  ---> eventual GCP intake
```

All four providers should receive only ciphertext plus signed metadata. Dropbox is convenience/redundancy, not a restore authority. R2 supplies normal restore bytes but is not trusted to decide what those bytes mean. The signed manifest/digest lineage does that.

**v0.2.0 does not yet perform R2/GCP/B2/Dropbox transport.** It implements the local cryptographic stake/restore root first and intentionally introduces no long-lived cloud bearer credentials. Remote upload, authoritative GCP catalog/head, R2 fetch, B2 replication, and Dropbox intake are the next layer once the actual provider endpoints and hardware/short-lived access path are configured.

## Current validation boundary

The package is exercised with Swift unit tests and release compilation on Linux. The macOS-only `Security.framework` / CryptoKit PIV path and real Docker Sandbox lifecycle must be validated on the target Mac because this build environment has neither the user's YubiKey nor macOS Security.framework nor the local `sbx` daemon. See `VALIDATION.md` and `QUICKSTART.md` for the exact smoke test.

### Preserve and select release artifacts

Use `./scripts/release /absolute/path/to/new-output` to build and carry the same
`Sim.app` through signing, notarization and installation. The output directory
must be new; an existing directory is rejected. Each later step also accepts its
bundle explicitly: `scripts/sign APP_PATH`, `scripts/notarize APP_PATH`, and
`scripts/install APP_PATH`. No argument retains the default `release/Sim.app`.
Notarization uses its own temporary ZIP and preserves earlier release archives.

`Tests/release-artifacts.sh` checks path selection (including spaces), ZIP
preservation and failure cleanup with fixture tools. It does not qualify Apple
signing, notarization, Gatekeeper or privileged installation. Those require the
configured personal Developer ID certificate and notary profile.

## Remote agent fleet (experimental)

The [remote fleet implementation](fleet/README.md) adds terminal deployment,
hardware-signed grants, OIDC workload identity, GCP nested microVM workers and
agent root inside rootless Podman containers. It includes planning for 200
agents, encrypted evidence/results and a separate model/package gateway.
Read its qualification requirements before deployment; real cloud capacity and
hardware-token operation are not established by the local test suite.
