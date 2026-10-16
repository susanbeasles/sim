# Security model — agent v0.2.0

The controller assumes the coding model is untrusted and may be actively malicious. Isolation therefore comes from the VM/controller boundary, not from asking the model to behave.

## Host repository

The host repo is never mounted read-write into the agent VM. Source is copied in without `.git`; the sandbox receives a synthetic Git repository. `agent diff` and `agent review` are read-only. Only `agent git ...` intentionally imports candidate changes back to the host.

## Controller trust

Release builds live inside a sealed Developer ID signed/notarized `Agent.app`. The runtime trust gate verifies the bundle seal, identifier, Team ID, and signing requirement and provides no `--insecure` bypass.

The protected transaction signer must be an OpenSSH FIDO/security-key (`sk-*`) credential. The release build pins the exact public-key SHA-256 fingerprint. Software SSH private keys are rejected even in development configuration.

## Staked-image trust

Each stake has two distinct hardware-backed roles:

1. FIDO signs the exact canonical stake manifest.
2. PIV unwraps the random AES-256 image key during restore.

The PIV private key must be represented by macOS as an external token-backed key (`kSecAttrTokenID`) and must support RSA-OAEP-SHA256 decrypt. Software Keychain identities are not eligible.

Image encryption is chunked AES-256-GCM. The ciphertext digest is checked before any private-key operation. After unwrap/decryption, the plaintext template digest is checked before `sbx template load`.

The manifest also signs the parent stake ID and parent manifest digest. Restore verifies every signature and every contiguous parent link back to a parentless generation 0. Tags are immutable per repository.

The local `index.json` is explicitly untrusted cache metadata. Resolution is rebuilt from manifest/signature files.

A matching plaintext stake template is not trusted as cache. Stake removes the template produced by `sbx template save`; restore removes a pre-existing matching tag, loads the verified tar, creates the sandbox, and removes the temporary loaded tag again.

## Secret baking prevention

Before a VM is staked, the controller refuses obvious credential files in the agent home, including common AWS/GCP/rclone credentials, `.netrc`, `.npmrc`, Claude/Codex credential files, and private `~/.ssh/id_*` files. This is a guardrail, not a proof that arbitrary application data contains no secrets.

## Audit

Full-audit vendor sessions are wrapped by a real-VM-root supervisor. The vendor runs as UID 0 only inside a child user namespace after supplementary groups are cleared. The supervisor records PTY streams, raw syscall traces, command metadata, and a hash-chained guest head. A separate host ledger records controller/lifecycle events.

This does not decrypt vendor TLS and does not claim visibility into remote provider internals.

## Cloud boundary

The planned provider set is GCP + Cloudflare R2 + Backblaze B2 + Dropbox. No AWS/S3 dependency is part of this design.

Remote stores are intended to receive ciphertext and signed metadata only. R2 may be the normal byte source but is not a root of trust. GCP is intended as authoritative write/anchor, B2 as another retained replica, and Dropbox as convenience redundancy/intake.

Cloud transport is not implemented in v0.2.0. This is deliberate: the release does not introduce long-lived cloud bearer credentials while the desired hardware/short-lived access path is still being configured.

## Non-goals / limits

- macOS root can still attack a running local environment; the hardware key primarily protects the signed/remote image lineage and prevents a copied vault from being decrypted without the token.
- An already-created workspace has a local plaintext baseline template for ordinary reset. `agent create -i ...` is the hardware-gated reconstruction path in v0.2.0.
- The credential-file preflight cannot recognize every possible secret embedded in arbitrary files.
- Full audit is strong local observation, not omniscient observation of encrypted remote traffic.
