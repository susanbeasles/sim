# Architecture — agent v0.2.0

## Trust boundaries

```text
macOS host
  |
  +-- sealed/notarized Sim.app
  |      |
  |      +-- host repo under ~/code        (never VM-mounted read/write)
  |      +-- /usr/local/var/agent          (controller state + encrypted vault)
  |      +-- YubiKey FIDO                  (manifest / boundary authorization)
  |      +-- YubiKey PIV                   (vault key unwrap)
  |      +-- signed sbx executable
  |
  +-- Docker sandboxd
          |
          +-- mountless VM
                 |
                 +-- $HOME/code/<repo>
                 +-- synthetic .git
                 +-- real-root audit supervisor
                 +-- fake-root vendor worker namespace
```

## Stake format

A stake is addressed by repository + generation, immutable tag, or UUID. Generation 0 is genesis. Each later manifest signs the UUID and SHA-256 digest of its parent manifest.

```text
StakeManifest
  schemaVersion
  id
  generation
  immutable tag
  createdAt
  repo / branch / vendor
  Docker Sandbox template tag + sbx version
  context repo list / audit mode
  parent stake UUID
  parent manifest SHA-256
  host + guest audit heads
  artifact:
    object key
    ciphertext SHA-256
    plaintext SHA-256
    sizes
    AES-GCM chunk size
  keyWrap:
    rsa-oaep-sha256
    PIV certificate SHA-256
    wrapped 32-byte AES key
```

Canonical JSON is signed with `ssh-keygen -Y sign` under namespace `agent-control` using the configured FIDO `sk-*` key. A release build pins that key's SHA-256 fingerprint.

## Encryption container

The image payload uses a simple streamable controller-owned container:

```text
magic        AGTVLT01
version      UInt32 BE
chunkBytes   UInt32 BE

repeated:
  index      UInt64 BE
  length     UInt32 BE
  AES-GCM combined record

sentinel:
  UInt64.max
  0
```

Each chunk uses AES-256-GCM and authenticates both the fixed header and chunk index as AAD. The signed plaintext digest additionally prevents valid-prefix truncation from becoming a valid image.

The image data key is generated randomly for every stake. Only that 32-byte key is wrapped to the PIV RSA public key. The private PIV key never leaves the hardware token.

## Restore authority

`index.json` is not authority. The store scans manifest files, requires a matching signature file, checks uniqueness, and treats the index only as a consistency cache.

Before a selected image is used, `VaultService` verifies:

```text
selected manifest FIDO signature
        |
        v
signed parent UUID + digest
        |
        v
parent signature
        |
       ...
        |
        v
generation 0, parentless
```

Then:

```text
ciphertext bytes
    |
    +-- SHA-256 == signed manifest? ---- no --> fail
    |
    v
touch/PIN YubiKey PIV
    |
    v
unwrap AES key
    |
    v
stream AES-GCM decrypt
    |
    +-- plaintext SHA-256 == signed manifest? -- no --> fail
    |
    v
remove same-tag local sbx template
load verified tar
create mountless sandbox
remove temporary loaded template tag
```

This makes R2/GCP/B2/Dropbox transport replaceable: a provider supplies bytes, not truth.

## Local plaintext state

A running sandbox is naturally plaintext. A normal workspace also has a local baseline Docker template so `agent reset` is fast and does not require the hardware key. The cryptographic stake is for durable/reconstructible lineage, not for pretending a currently running Mac has no plaintext.

The plaintext template created specifically to export a stake is removed immediately after encryption, and the plaintext template temporarily loaded for an image restore is removed after sandbox creation.

## Planned provider topology

```text
GCP
  authoritative write + signed catalog/head + retained anchor
    |
    +--> R2       hot/read replica
    +--> B2       retained replica

Dropbox
  ordinary encrypted backup/sync
    |
    +--> eventual GCP intake
```

Normal restore should fetch ciphertext from R2, then validate it entirely against signed content metadata before PIV unwrap. GCP should determine authoritative signed catalog/head state; R2 object names/listings must never decide `latest`.

This transport is not wired in v0.2.0.

## Host Git import

The image feature does not change the existing host-source boundary. Candidate import still uses BASE/OURS/THEIRS semantics and only `agent git ...` may mutate the host working tree/index/history.
