# Guest audit completeness

The guest ledger belongs to real VM root. A session is one vendor invocation,
identified by its worker and session ID. The host control ledger records the
launch intent and accepts completion only after verifying the guest evidence.

## Invariants

- Before vendor execution, a session's immutable start manifest and start record
  are written, chained, and flushed with `sync`.
- A completion record follows execution and includes the final evidence manifest.
  Start and completion both consume a sequence number and bind their phase into
  the chain digest.
- Verification checks every chain entry and enumerates all session directories.
  Missing, duplicate, malformed, unreferenced, or incomplete sessions fail
  verification. A valid older chain prefix cannot hide a later interrupted run.
- Full audit binds the host-generated session ID and verified prior sequence/head
  into the launch and the subsequent guest verification request. The head must
  change and the sequence must advance by two before `session.end` is recorded.
  Failure throws and records `session.audit.failed` when the host ledger remains
  writable. A verified vendor failure still returns the vendor's exit code.

## Compatibility and operation

Existing three-column completed entries retain their original digest format.
New entries add a fourth column, `start` or `complete`. Historical entries cannot
stand in for the completion of a new host-bound session.

Before each full-audit launch, the host refreshes both guest helpers by staging
them in the root-only helper directory and renaming them into place. This also
updates existing workspaces without replacing their audit ledger. Control-only
launches retain their previous optional guest-head behavior.

Verification intentionally fails while a session is incomplete. Overlapping
launches or a changed prior head fail closed; this is not a concurrent snapshot
protocol. Failed evidence is retained for investigation and archival, never
automatically repaired or discarded. A pristine ledger permits a zero-sequence
snapshot; a damaged or emptied ledger does not.

## Validation boundary

`GuestAuditTests` executes the emitted scripts against temporary ledgers. It
covers completed and interrupted sessions, a finalization write error after
child execution, orphan directories, malformed entries, exact session/prior-head
binding, pristine snapshots, and extension of a historical ledger.
`SessionAuditTests` exercises the host service through its process boundary,
including stale/malformed heads, failed verification, helper upgrade, and
preservation of a verified vendor exit code.

On macOS, the guest tests adapt `flock`, `runuser`, and util-linux `script` at the
process boundary. They verify ledger behavior, not Linux locking, user namespaces,
PTY capture, VM power-loss durability, or actual disk exhaustion. Those require
qualification in a Linux guest. The reported finding was verified in the source
at revision `a2bcf1c`; the original report used `f3c70ce`.
