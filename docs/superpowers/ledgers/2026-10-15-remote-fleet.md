# Remote fleet implementation ledger

## Scope and decisions

- User authorized implementation in susanbeasles/sim and clarified that agent UID 0 belongs inside a rootless container, within a per-task microVM.
- Base: 0a3714ae0c1456dffabd9b6432879c31d92c832e. Branch: work/remote-agent-fleet.
- Kept protected guard, instruction, workflow and harness directories untouched. The explicit connected-GitHub request authorizes repository access despite the generic no-network repository guideline.
- Kept hardware authority in the existing Mac executable. Node 24 implements cloud services and the remote terminal client without npm dependencies. No software signing fallback or cloud key capture was introduced.
- Import uses a fresh validated review tree and hardware-authorized three-way staged patch, requiring a clean host index/tree.
- Infrastructure is owner-applied OpenTofu. No cloud resources have been provisioned by this implementation session.

## Verification and implementation evidence

- Core RED/GREEN: canonical grants, policy bounds, nonce replay, SQLite persistence, task allowance, fencing, cryptographic tampering, Google JWT verification.
- Service integration: actual HTTP controller and SQLite restart with 200 tasks; real crypto/source extraction/result sealing; streaming HTTP gateway; independent audit ordering/idempotence.
- Runtime/provider tests replace external execution and HTTP boundaries; these do not establish real KVM, Podman or GCP operation.
- Startup fix RED/GREEN: renew before guest preparation, continue renewal throughout it, explicitly pin the signed model/provider and install Node's public CA environment.
- Dispatch fix RED/GREEN: locked grants retain queued tasks; pause persists across restart.
- `make check`: 31 Node tests and 2 Python exporter tests pass, release shell fixtures pass, JavaScript syntax, shell syntax and Python syntax pass.
- `git diff --check`: passes.

## Qualification still required

This environment lacks Swift, KVM, sbx, Podman, GCP tooling and OpenTofu. The Mac build/token path, actual nested microVM/rootless/cgroup/ptrace operation, provider API contracts, Terraform provider validation, headless Docker enrollment and the progressive 200-agent load test are not established by local tests. README records target-host acceptance steps and bootstrap inputs. The feature is delivered for review and target-host qualification, not asserted production-ready.

## Independent review

Final independent reviewer: merge with documentation fixes, as a draft awaiting target qualification. No unresolved critical code finding in the inspected final patch set. Promised documentation now describes Vertex counting, HTTPS package requirements, credit reservations, endpoint delegation and shared-CDN/domain-fronting limits.

Important findings fixed and tested or inspected:

- Authenticate release files with trusted host tools before running bundle code as root.
- Supply GCP instance service-account attachment permission.
- Make source accessible to rootless Podman; consume exported tar as guest root with bounded safe parsing.
- Reject source directory symlink traversal and final-file links; use checked O_NOFOLLOW reads.
- Isolate synthetic Git review from global/system filters and force-add original ignored files.
- Reserve concurrent grant budgets atomically; retain queued work while broker is locked; persist pause.
- Retry provisioning using stable request IDs and retry deletion until completion.
- Renew leases during preparation, pin model/provider/CA and restore stdin ordering.
- Drain all log pages and cap concurrent artifact cache writes.
- Bound model gateway bodies/concurrency; bound proxy setup, concurrent sessions, public-address resolution, byte reservations and absolute lease deadlines.
- Retry TLS secret bootstrap through systemd; rotate to latest valid role secret on restart.

Review dispositions for declined-to-judge behaviors:

- Mac/Swift/PIV and actual runtime/cloud/model/package-manager behavior: accepted as mandatory target qualification; unavailable in this execution environment. Not represented as passing.
- Sustained 200-agent density/memory/throughput/recovery: accepted as measured acceptance work; estimates are not benchmarks.
- Compromised trusted roots, confidential computing, exact dollar ceilings and DLP: explicit trust-model limits. CONNECT delegates network endpoint access and does not inspect TLS application authority; strict deployments must use owner-controlled mirrors or disable egress.
- Malicious concurrent local filesystem mutation: outside the remote-agent boundary. Static symlink escapes were reproduced and rejected.
- Legacy local import and protected policy files: left unchanged; remote review/import has its own authorization path.

Automatic approval review blocked the first Vertex test because its default token callback would contact Google metadata. Replaced that boundary with an injected test token and verified all tests without live metadata, credential reads or provider calls. No approval escalation or bypass was attempted.

Final gate evidence: make check and the repository .guard/checks/on-stop complete successfully, with Swift and gitleaks explicitly skipped because absent. git diff --check passes; protected file/directory diff is empty. No cloud resources were created.
