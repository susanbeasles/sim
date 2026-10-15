# Remote Fleet Implementation Plan

> For agentic workers: use superpowers:executing-plans to implement task by task.

**Goal:** Deploy and operate private Linux hosts running isolated Claude/Codex tasks with container root inside a rootless guest runtime.

**Architecture:** Keep Swift hardware authority local. Add dependency-free Node 24 fleet services, durable SQLite leases, authenticated polling workers, a model gateway, and GCP infrastructure.

**Tech Stack:** Swift 6, Node 24, SQLite, OpenSSH, sbx, rootless Podman, OpenTofu, GCP.

**Spec:** ../specs/2026-10-15-remote-fleet-design.md

## Global Constraints

- Agent UID 0 maps to an unprivileged guest user; guest-root supervisor remains outside the container.
- Node 24+, no npm dependencies, immutable image digests, no secrets in templates or infrastructure state.
- Existing local source import, PIV authority and protected repository policy files remain intact.
- Billable deployment is operator-run; all new cloud writes require an exact signed fleet grant.

## Review Focus

- Replayed/expired grants and concurrent requests cannot multiply authority.
- Lease renewal, process restart and scale-down cannot lose or duplicate accepted work.
- JWT issuer/audience/subject and host provenance checks reject impersonation.
- Task IDs, archive paths, command arguments and URLs cannot reach management authority.
- Full disks, log saturation and unavailable collectors fail closed visibly.

### Task 1: Policy and durable authority

Files: fleet/src/{policy,store,auth,canonical}.mjs and fleet/test/core.test.mjs.
Interfaces: validateConfig, canonical, Store, verifyGoogleToken, verifyHardwareSignature.
- [ ] Write rejection, replay, resource packing, JWT and restart tests; run RED.
- [ ] Implement strict validation, canonical signatures, SQLite transactions and leasing.
- [ ] Run the core tests GREEN.

### Task 2: Remote services and host execution

Files: fleet/src/{controller,worker,runtime,gcp,gateway,audit,artifacts}.mjs, fleet/guest/*.
Interfaces: createController, createGateway, Worker, SBXRuntime, GCPProvider.
- [ ] Write real HTTP/SQLite integration and runtime-boundary tests; run RED.
- [ ] Implement authenticated APIs, scheduling/reconciliation, typed runtime calls, rootless execution, candidates and independent audit.
- [ ] Run all Node tests GREEN including restart and 200-task allocation.

### Task 3: Terminal workflow and deployment

Files: fleet/bin/*, fleet/infra/gcp/*, fleet/deploy/*, Sources/sim/FleetCLI.swift, scripts/build, fleet/README.md.
Interfaces: sim fleet / sim remote, signed manifest file handoff, verified release bundle.
- [ ] Write CLI subprocess, source transfer and deployment-render tests; run RED.
- [ ] Implement CLI, Swift dispatch, infrastructure, host bootstrap and operating guide.
- [ ] Run complete Node checks, shell parsing, original release-artifact tests and repository completion gate.

### Task 4: Final review

- [ ] Review complete diff with a fresh reviewer; fix important findings with regression tests.
- [ ] Record actual verification and platform/cloud validation limits.
- [ ] Commit and publish a feature branch and reviewable pull request.
