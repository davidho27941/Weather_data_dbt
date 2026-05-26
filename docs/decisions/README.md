# Design decisions

Short notes about decisions that aren't obvious from reading the code, and where the alternatives considered and the rejection reasons would otherwise be lost. Written as needed, not on a schedule.

Format is intentionally lightweight:

- **Status** — `Proposed` / `Accepted` / `Deprecated` / `Superseded by NNN`
- **Date** — when the decision landed (or when status changed)
- **Context** — the situation that forced a choice
- **Decision** — what we chose
- **Alternatives considered** — what we explicitly rejected, briefly
- **Consequences** — what becomes easier, harder, or worth watching

Immutable once `Accepted`. To change a decision, write a new note that
supersedes the old one and update the old one's Status.

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [001](001-string-typed-bronze-sentinels.md) | STRING-typed bronze observations preserve CWA sentinels | Accepted | 2026-05-09 |
| [002](002-dual-column-raw-cleaned-staging.md) | Dual-column raw + cleaned staging pattern | Accepted | 2026-05-10 |
| [003](003-enforce-dbt-contracts-on-marts.md) | Enforce dbt model contracts on the marts layer | Proposed | 2026-05-11 |
| [004](004-cwa-precipitation-sunshine-are-daily-cumulative.md) | CWA `Precipitation` and `SunShine` are daily-cumulative, not 10-min windows | Proposed | 2026-05-26 |

## Why these four

Most decisions in this project are either obvious (GCP, BigQuery, dbt — standard tools) or already documented in PR descriptions. These four are kept here because:

- **001** explains a non-obvious choice (storing sentinels as STRING rather than nulling them at ingest) that constrains everything downstream.
- **002** explains the dual-column raw + cleaned pattern, which is the most distinctive piece of staging in this repo.
- **003** is forward-looking — written before the implementation PR so the design discussion isn't buried under column-by-column type review.
- **004** documents a CWA-spec semantics finding (`Precipitation` / `SunShine` are daily-cumulative, not 10-min windows) that future reviewers cannot recover from the code alone, and pins the LAG-diff derivation rules that the staging layer now depends on.

For the broader v2 design narrative see [`../redesign_proposal.md`](../redesign_proposal.md). PR descriptions in git history hold what-and-why for individual changes.

## Template

```markdown
# Title in present tense

## Status

Proposed | Accepted | Deprecated | Superseded by NNN

## Date

YYYY-MM-DD

## Context

The situation, the forcing function, what's in tension.

## Decision

What we will do.

## Alternatives considered

- **Option A** — why we rejected it.
- **Option B** — why we rejected it.

## Consequences

- **Easier:** ...
- **Harder:** ...
- **Watch out for:** ...
```
