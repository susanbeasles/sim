# `agent` v0.2.0 quick start

This is a source release. Build/sign/notarize it on the Mac that owns the Developer ID identity; do not install an unsigned replacement into `/usr/local/bin/agent`.

## 1. Unpack and validate source

```bash
mkdir -p ~/code
cd ~/code
tar -xzf ~/Downloads/agent-cli-v0.2.0.tar.gz
cd agent-cli-v0.2.0

./scripts/init-usr-local
./scripts/check
```

## 2. Pin the FIDO/YubiKey signer into the release

Confirm the existing SSH key is actually a security-key credential:

```bash
head -n 1 ~/.ssh/id_yubikey.pub
ssh-keygen -lf ~/.ssh/id_yubikey.pub -E sha256
```

The first field must be an OpenSSH `sk-*` key type. Copy the SHA-256 fingerprint into the release config:

```bash
cp config/release.env.example config/release.env
$EDITOR config/release.env
```

Set:

```text
AGENT_BUNDLE_ID=<your reverse-DNS identifier>
AGENT_TEAM_ID=<Apple Developer Team ID>
AGENT_SIGNING_IDENTITY="Developer ID Application: ... (<TEAMID>)"
AGENT_NOTARY_PROFILE=agent-notary
AGENT_AUTH_KEY_FINGERPRINT="SHA256:..."
AGENT_VERSION=0.2.0
```

Store notarization credentials in Keychain once, then release:

```bash
./scripts/setup-notary agent-notary YOUR_APPLE_ID YOUR_TEAM_ID
./scripts/release
```

Verify:

```bash
command -v agent
agent version
agent doctor
```

## 3. Configure the FIDO signer

```bash
agent config auth-key ~/.ssh/id_yubikey
```

A plain `ssh-ed25519`/RSA software key is intentionally rejected. The public-key fingerprint must also match the fingerprint embedded in the signed release build.

## 4. Discover a hardware PIV identity

Insert the YubiKey and run:

```bash
agent key identities
```

Output is:

```text
<CERT_SHA256>  vault-ok|incompatible  <KEY TYPE/BITS>  <TOKEN ID>  <SUBJECT>
```

Only identities backed by an external macOS token store are shown. Pick a `vault-ok` identity and configure its certificate fingerprint:

```bash
agent config piv-cert <CERT_SHA256>
agent doctor
```

If there is no `vault-ok` identity, **stop**. This package does not overwrite or provision PIV slots automatically. Inspect the existing PIV layout first, then decide deliberately whether to create a dedicated RSA key-management identity.

## 5. Create a normal sandbox

```bash
cd ~/code/triggr_api
agent create --repo triggr_api --vendor cc --state clean
```

Or use Codex:

```bash
agent create --repo triggr_api --vendor gpt --state clean
```

## 6. Stake generation 0

```bash
agent stake -t 'root baseline'
```

Expected behavior:

```text
freeze/export template
stream-encrypt with AES-256-GCM
wrap 32-byte image key to hardware PIV certificate
remove plaintext stake template from sbx image store
Touch YubiKey to authorize exact signed manifest...
STAKED
repo       triggr_api
generation 0
...
```

The encrypted object/manifests live under:

```text
/usr/local/var/agent/vault/
  objects/
  manifests/
  signatures/
  index.json
```

`index.json` is only a cache.

## 7. Verify and restore

Cheap verification (manifest lineage + signature + ciphertext digest):

```bash
agent image verify 0
```

Deep verification also unwraps/decrypts and checks plaintext SHA-256:

```bash
agent image verify 0 --deep
```

Create a new sandbox from the exact genesis image:

```bash
agent create --repo triggr_api -i 0
```

Expected trust ceremony:

```text
signed lineage................ verified
ciphertext SHA-256............ verified
Touch YubiKey to unlock genesis image...
plaintext SHA-256............. verified
sandbox....................... created
```

The restore path removes any pre-existing Docker template carrying the signed template tag, loads only the just-verified tar, creates the sandbox, then removes that temporary template again.

## 8. Daily aliases

```zsh
alias cc='agent claude'
alias codex='agent codex'
```

Do not install `/usr/local/bin/cc`; `/usr/bin/cc` is the system C compiler.

## Current transport boundary

v0.2.0 does **not** yet upload/fetch the stake through GCP/R2/B2/Dropbox. Do not interpret a successful local stake as remote replication. The next layer is:

```text
GCP = authoritative write/anchor
R2  = normal restore-byte source/cache
B2  = retained replica
Dropbox = convenience backup/sync -> eventual GCP intake
```

That layer will move only encrypted objects and signed metadata; the providers never need the plaintext image or the PIV private key.
