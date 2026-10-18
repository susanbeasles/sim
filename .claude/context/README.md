# .claude/context

This directory is the durable memory of the engineering practice used in this repo. It is part of the source code. Treat it that way.

## Purpose

Agents (and humans) working in this codebase do not start from zero. They start from the conclusions captured here: the ubiquitous language, the bounded contexts, the entities and their invariants, the decisions made and the reasons for them, the active feature specs.

Without this directory, every agent re-investigates the domain. With it, every agent stands on the prior agent's work.

## Files

- `glossary.md`: the Ubiquitous Language. Every domain term, its precise meaning, and the bounded context it belongs to.
- `bounded-contexts.md`: the map of contexts in this system and the relationships between them.
- `entities.md`: entities, value objects, aggregates, and the invariants each protects.
- `invariants.md`: domain rules that must always hold, with where they are enforced.
- `decisions/`: Architecture Decision Records, one per decision, numbered sequentially.
- `specs/`: feature specs with acceptance criteria. One file per feature.

## Rules

1. **Read before writing.** Before producing or recommending code, read the files relevant to the area being worked on. Skipping this is the failure mode that destroys the practice.

2. **Update in the same commit.** Any change that touches domain semantics updates the relevant file here in the same commit. PRs that change behavior without updating context should be rejected.

3. **One concept, one name.** If a concept exists in `glossary.md`, use that name. Do not invent synonyms.

4. **Reconcile drift immediately.** If a discrepancy is found between code and context, fix one of them in the same change. Stale context lies with authority and is worse than no context.

5. **Keep files lean.** Each file has a single job. Resist the temptation to dump prose. Lists, tables, and short paragraphs over long essays.

## How to maintain

This directory is maintained by the team. Reviewers verify that PRs touching domain semantics include context updates. New domain terms are added to the glossary on first use. New invariants are recorded as they are discovered or designed.

The domain-first-engineering skill bootstraps and maintains this directory on first run. Subsequent runs read it and update it as work proceeds.
