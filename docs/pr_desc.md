# Design decision notes (PR #8)

## Summary

Adds [`docs/decisions/`](../docs/decisions/) with three short notes
about non-obvious design choices in this repo. Format borrows from
ADRs (Status / Date / Context / Decision / Alternatives / Consequences)
but intentionally without the ADR framing — these are working notes
written when they earn their keep, not a process to perform.

The three notes:

| # | Title | Status |
|---|---|---|
| [001](../docs/decisions/001-string-typed-bronze-sentinels.md) | STRING-typed bronze observations preserve CWA sentinels | Accepted |
| [002](../docs/decisions/002-dual-column-raw-cleaned-staging.md) | Dual-column raw + cleaned staging pattern | Accepted |
| [003](../docs/decisions/003-enforce-dbt-contracts-on-marts.md) | Enforce dbt model contracts on the marts layer | **Proposed** |

## Why this scope (and not more)

Earlier drafts of this PR carried seven entries covering every v2
choice (GCP-over-Snowflake, Cloud Run Job vs orchestrator, single TF
root, weekly dbt cadence, etc.). Cut deliberately to three. Reason:
retrospective decision-notes for choices already documented in PR
descriptions are decoration. Solo project + same week's decisions is
the worst possible signal-to-noise for "ADR culture as portfolio
prop". Kept the two retrospectives that genuinely add value:

- **001** — bronze sentinels constrain the whole staging layer; the
  alternatives (NULL-at-ingest, sentinel-flag columns, JSON) aren't
  obvious from reading the code.
- **002** — the dual-column raw + cleaned pattern is the single most
  distinctive piece of staging in this repo, and "why not just
  cleaned columns" is the most common reaction to it.

The third (**003**) is forward-looking: it's the design record for
the dbt-contract-enforcement change that lands in the next PR. Writing
it now creates a decide-before-implement gate so the design review
and the column-by-column type review happen on different PRs.

Other v2 choices (GCP, Cloud Run, weekly cadence, etc.) are standard
SaaS choices already covered adequately in [`README.md` § Migration
history](../README.md#migration-history) and the original
[`docs/redesign_proposal.md`](../docs/redesign_proposal.md). A note
that just restates "we picked the obvious tool" doesn't earn the file.

## What's in this PR

### `docs/decisions/README.md`

Lightweight index + template + a "Why only three" section explaining
what's *not* covered and where the broader design narrative lives.
Format spec is half a page; no Nygard reference, no ceremony.

### Three notes

Files are numbered `NNN-kebab-title.md`. Headings are the decision
title in present tense (no "Note:" / "ADR:" prefix). Cross-references
between notes use the number (e.g. "decision 001").

001 and 002 are `Status: Accepted` with the date pulled from the
original merge timestamps. 003 is `Status: Proposed` — it will flip
to `Accepted` in the same commit that lands the implementation in the
next PR.

### README updates

- Repository layout: `docs/` row now mentions `decisions/`.
- Migration history: PR #8 bullet added (both EN and JP).
- Future work: dbt-contract bullet now points at decision 003.

## Changes

| File | Change |
|---|---|
| [`docs/decisions/README.md`](../docs/decisions/README.md) | New: index + template + scope explanation |
| [`docs/decisions/001-string-typed-bronze-sentinels.md`](../docs/decisions/001-string-typed-bronze-sentinels.md) | New: retrospective, Accepted |
| [`docs/decisions/002-dual-column-raw-cleaned-staging.md`](../docs/decisions/002-dual-column-raw-cleaned-staging.md) | New: retrospective, Accepted |
| [`docs/decisions/003-enforce-dbt-contracts-on-marts.md`](../docs/decisions/003-enforce-dbt-contracts-on-marts.md) | New: forward-looking, Proposed |
| [`README.md`](../README.md) + [`multilingual_readme/readme_jp.md`](../multilingual_readme/readme_jp.md) | Repo layout + Migration history + Future work |

## Test plan

Prose; no runtime. Verification is editorial:

- [x] Each note has Status, Date, Context, Decision, Alternatives
      considered, Consequences.
- [x] Alternatives sections enumerate at least two rejected options
      with reasons, not "we picked the best one" hand-waving.
- [x] All internal links resolve.
- [x] Index in `docs/decisions/README.md` matches the filenames.
- [x] Top-level README references the new directory.
- [ ] Reviewer reads each note and disagrees if any historical claim
      is wrong. **This is the actual review.**

## Out of scope

- **dbt contract implementation.** Lands in the follow-up PR. See
  decision 003 § Implementation plan.
- **Notes for choices already covered in PR descriptions** (GCP,
  Cloud Run Job, weekly cadence, single TF root). Deliberately not
  added — they'd be decoration.

## References

- Branch: `feat/design-decisions` → `main`
