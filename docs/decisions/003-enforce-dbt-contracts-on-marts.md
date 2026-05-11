# Enforce dbt model contracts on the marts layer

## Status

Proposed

## Date

2026-05-11

## Context

The marts layer (`dim_stations`, `fct_measurements_{10min,hourly,daily,weekly,monthly}`)
is the **contract boundary** with downstream consumers: ML training,
ad-hoc analysis, future BI tools. Today, that contract is implicit:

- Column names live in the `select` clause of each model.
- Column types are whatever BigQuery infers from the SQL expression.
- Schema changes (renames, type narrowing, column removal) compile
  cleanly and propagate without any explicit "this breaks consumers"
  signal.

PR #7 added strong **data quality** assertions via dbt tests
(`not_null`, `unique`, `accepted_range`, `relationships`, the
sentinel-translation invariant). What it did *not* add is **schema
contract** assertions — there is no compile-time guarantee that
`fct_measurements_10min.air_temperature` is still `FLOAT64` next week
and not, say, accidentally narrowed to `INT64` by a `CAST(... AS INT64)`
someone added to fix a different bug.

dbt 1.5+ exposes `contract: { enforced: true }` on model configs. When
enforced, dbt:

- requires every column in the model to have an explicit `data_type`
  in the YAML
- fails the build at compile time if the SQL would produce a different
  column type or set of columns than the YAML declares
- forces a deliberate, reviewable change when the schema legitimately
  needs to evolve

This is structurally the same idea as type annotations in code: make
the contract explicit, fail fast when it's violated, let the compiler
do the bookkeeping.

## Decision

Enforce `contract: { enforced: true }` on every model in the marts
layer:

- `dim_stations`
- `fct_measurements_10min`
- `fct_measurements_hourly`
- `fct_measurements_daily`
- `fct_measurements_weekly`
- `fct_measurements_monthly`

Every column in those models' `_models.yml` must carry an explicit
`data_type` matching what the SQL produces. dbt will refuse to compile
if they don't line up.

**Not** enforced on staging or intermediate models. Those are internal
to the build; their schema is not part of the consumer contract.
Enforcing there would add maintenance cost without a correctness
payoff.

## Alternatives considered

- **Rely on dbt tests only.** Tests run *after* the table is built —
  they catch bad data but not bad schema. A column renamed in SQL but
  not in YAML produces "test missing column X" at run time, not at
  compile time. Slower failure, harder to attribute.
- **Use SQL views with explicit CASTs to lock types.** Forces the
  types but leaves no compile-time check on column presence; removing
  a column from SQL silently drops it from the view.
- **dbt-expectations or great_expectations.** Strong on data-quality
  expectations (already what PR #7's tests are), but not the same
  thing as a schema contract. Different layer.
- **Defer until a real consumer breakage happens.** Tempting
  ("YAGNI") but the cost of adding contracts on day one of a consumer
  build is trivial, while retro-fitting them after a breakage already
  happened is more work AND has happened before the contract caught
  it. Cheaper now.

## Consequences

- **Easier:** schema changes become explicit, reviewable diffs in
  `_models.yml`; downstream consumers can rely on the marts schema
  the same way they rely on a typed API; "what columns and types does
  this table expose?" is answered by reading the YAML, not by
  introspecting BigQuery.
- **Harder:** initial type-out of every column (~60 columns across the
  six marts). One-time cost during implementation; afterwards, each
  schema change is a single-line YAML edit alongside the SQL change.
- **Watch out for:** type drift between SQL expression and the
  declared YAML type. Common surprises in BigQuery:
  - `COUNT(*)` returns `INT64`, not `NUMERIC`
  - `AVG(int_col)` returns `FLOAT64`
  - `TIMESTAMP_TRUNC(t, DAY, 'Asia/Taipei')` returns `TIMESTAMP`, not
    `DATE`
  - Window function over `FLOAT64` returns `FLOAT64`; over `INT64`
    returns `FLOAT64` (mean) or `INT64` (count) — verify per case.
  The implementation PR has to verify types in practice rather than
  guessing — `bq show --format=prettyjson PROJECT:DATASET.TABLE` after
  the next stg build gives the authoritative types.

## Implementation plan (separate PR)

This note is the design decision. The actual contract enforcement
lands in a follow-up PR that:

1. Adds `contract: { enforced: true }` to each marts model's `config`.
2. Adds `data_type` to every column in `models/marts/_models.yml`.
3. Runs `dbt build --target stg` to confirm types match.
4. Updates this note's Status to **Accepted** with the PR reference.

The split exists because pure design review (this PR) and
column-by-column type review (next PR) are different review modes —
combining them makes neither well-reviewed.

## References

- dbt model contracts:
  <https://docs.getdbt.com/reference/resource-configs/contract>
- Marts model definitions (today, pre-contract): [`weather_data_dbt/models/marts/_models.yml`](../../weather_data_dbt/models/marts/_models.yml)
- Related but distinct: data **quality** tests (PR #7) vs. schema
  **contract** enforcement (this note)
