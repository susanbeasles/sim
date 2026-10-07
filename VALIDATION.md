# Validation status — v0.2.0

## Automated validation completed in the build environment

`./scripts/check` runs:

```text
swift test
swift build -c release
git diff --check   (when inside a Git worktree)
bash -n scripts/*
```

The current suite covers:

- repository-name resolution under `~/code`;
- controller state round-trip;
- hash-chain audit tamper detection;
- SHA-256 known vector and streaming file hashing;
- backward-compatible config decode;
- hardware-only FIDO `sk-*` signer acceptance / software SSH key rejection;
- vault manifest commit/resolve;
- manifest/index tamper detection;
- duplicate-generation rejection;
- immutable duplicate-tag rejection;
- manifest discovery surviving deletion of the mutable index cache.

On October 7, 2026, `./scripts/check` passed all 12 tests and release compilation on the target Mac. The installed Docker Sandboxes CLI reports v0.45.0. This verifies native compilation and CLI availability; it does not yet verify daemon access, hardware unwrap, or a complete sandbox restore.

The release bundle is `Sim.app`, with executable `Contents/MacOS/sim`. Its generated Info.plist now names that installed executable. Shell syntax, whitespace checks, and a parsed-plist executable-path check passed after this correction.

## Must be validated on the target Mac

The following integration checks remain pending on the target Mac:

1. Qualify the compiled macOS CryptoKit/Security.framework branches with the intended hardware identity.
2. Confirm `agent key identities` sees the YubiKey PIV identity as an external token-backed key.
3. Confirm the chosen RSA PIV identity reports `vault-ok` and performs RSA-OAEP-SHA256 unwrap with the intended PIN/touch policy.
4. Run the complete `sbx template save --output` -> remove -> decrypt -> `sbx template load` -> create lifecycle against the installed `sbx` version.
5. Build/sign/notarize/staple and verify the installed `Sim.app`.

Run this smoke sequence on the Mac:

```bash
cd ~/code/agent-cli-v0.2.0
./scripts/check
./scripts/release

agent config auth-key ~/.ssh/id_yubikey
agent key identities
agent config piv-cert <VAULT_OK_CERT_SHA256>
agent doctor

cd ~/code/triggr_api
agent create --repo triggr_api --vendor cc --state clean
agent stake -t 'v0.2 smoke root'
agent image verify 0
agent image verify 0 --deep
agent create --repo triggr_api -i 0 --name triggr-api-genesis-smoke
agent status triggr-api-genesis-smoke
```

Do not provision or overwrite a PIV slot merely to make this smoke test pass. If there is no compatible identity, inspect the current token first.

## Intentionally not implemented yet

- GCP authoritative metadata/object upload.
- Cloudflare R2 normal restore fetch/cache.
- Backblaze B2 retained replication.
- Dropbox sync/intake workflow.
- Remote anti-rollback/head anchoring.
- `agent reset --origin` hardware-gated reconstruction.
- continuous filesystem/CAS time-machine revisions and `agent fork REV`.
- host-to-sandbox `agent git pull` reconciliation.

Those are separate layers; v0.2.0 should not claim them merely because the cryptographic local stake format exists.

Release packaging accepts a new output directory: `scripts/build /absolute/path/to/new-output`. It refuses any existing output before changing the build identity, preserving earlier release artifacts. With no argument it targets `release`, which must be absent. Signing and installation scripts continue to use `release/Sim.app`; a separate output supports inspection and qualification before replacing any prior artifact through an operator-approved release procedure.
