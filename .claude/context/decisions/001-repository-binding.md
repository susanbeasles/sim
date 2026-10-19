# Repository binding for stakes

Stake selection, generation allocation, immutable tags, parent lineage and restored
workspace binding use the exact canonical host Git root stored in the signed
`repoPathHint`, rather than a repository directory basename. Restore checks this
binding before PIV unwrap and again before workspace creation. Every parent link
must retain the same repository path, alongside the existing signature and
manifest-digest checks.

Legacy stakes remain valid at their original path only when their entire parent
lineage uses that same path. Basename-scoped histories may contain parents from
another path; these mixed-path histories fail closed during restore and when
verifying the latest parent before creating another stake. Automatic recovery of
mixed-path histories is not implemented. Moving a repository requires creating a
new stake at the destination.

A canonical path is not a portable repository identity and cannot distinguish a
replacement repository at the same path. This binding does not relax signature,
hardware-key or parent-lineage verification.
