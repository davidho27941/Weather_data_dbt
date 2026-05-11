# Dual-column raw + cleaned pattern at staging

## Status

Accepted

## Date

2026-05-10 (PR #3)

## Context

Decision [001](001-string-typed-bronze-sentinels.md) mandates that
bronze stores measurement values as STRING with CWA sentinels
preserved. Staging has to convert these strings into FLOAT64 for
downstream use, but the conversion is **lossy** in two ways:

1. **Sentinel value erased.** `'-99'` and `'X'` both become NULL — the
   why-it's-missing context is gone.
2. **Semantic-zero collapse.** `'T'` (trace) and `'-98'` (no rain in
   past 6h) become numeric `0`, but they originated from semantically
   different states (vs. e.g. `'0.0'` which is also `0` but means
   "measured and confirmed dry").

Different consumers want different views:

- **ML training** wants `FLOAT64`, sentinels as NULL or `0` per the
  documented translation rules. Predictable. Tabular.
- **Governance / debugging / data quality** wants the raw value
  verbatim. "Why is this row's air_pressure NULL?" needs the raw
  column to answer.
- **Downstream consumers in the future** may want either. We don't
  want to force a "choose one" decision now that's hard to reverse.

## Decision

Every sentinel-bearing measurement field is exposed at staging as
**two columns**:

```
<field>_raw   STRING    original CWA value, verbatim
<field>       FLOAT64   sentinel-translated, ready for ML
```

`cwa_string_to_float` is the single source of truth for the
translation rules. The `_raw` column carries no transformation at
all — it's bronze STRING projected through.

Both columns propagate from `stg_observations` through
`int_measurements__cleaned` and into `fct_measurements_10min`. The
time-grain rollup facts (hourly/daily/weekly/monthly) drop the raw
columns because aggregation across a bucket can't preserve them
coherently.

## Alternatives considered

- **Cleaned column only.** Smallest schema. ML pipelines happy.
  Governance and debugging are broken — restoring the raw value
  requires re-querying bronze. Information that's "trivial to keep
  forwards" should not be discarded.
- **Raw column only.** Smallest schema, no information loss. ML
  pipelines either consume STRING (forcing every downstream model to
  re-implement sentinel translation) or pay the translation cost in
  their own SELECT (fragile, easy to skip).
- **Separate raw and cleaned tables.** Information preserved but every
  downstream query joins two tables on `(station_id, measure_at)`.
  Query plan cost and developer ergonomics both worse than carrying
  the columns side-by-side.
- **STRING column + sentinel-flag columns.** Avoids the FLOAT cast cost
  but explodes column count (one flag per sentinel per field) and
  pushes the cast cost to every downstream consumer anyway.

## Consequences

- **Easier:** ML training queries `<field>` and forgets sentinels
  exist; governance queries `<field>_raw` and sees CWA's encoding
  unmodified; sentinel translation rules concentrated in one macro;
  the `sentinel_translation_invariant` test (PR #7) statically asserts
  the contract holds across the entire dataset.
- **Harder:** ~2× column count at staging and `fct_measurements_10min`
  vs. cleaned-only. Storage cost trivial at our volume; query cost
  affected only if a consumer does `SELECT *` (don't). Schema diff
  between 10-min fact and the rollup facts can confuse readers —
  documented in the model description, but a real cognitive load.
- **Watch out for:** rollup facts losing the raw column means "why is
  this aggregate value odd?" debugging has to go back to the 10-min
  fact. Acceptable today; if downstream consumers routinely need raw
  context at hourly/daily grain, the design needs revisiting.

## References

- Staging implementation: [`weather_data_dbt/models/staging/stg_observations.sql`](../../weather_data_dbt/models/staging/stg_observations.sql)
- Translation macro: [`weather_data_dbt/macros/cwa_string_to_float.sql`](../../weather_data_dbt/macros/cwa_string_to_float.sql)
- 10-min fact preserving both columns: [`weather_data_dbt/models/marts/measurements/fct_measurements_10min.sql`](../../weather_data_dbt/models/marts/measurements/fct_measurements_10min.sql)
- Statically-enforced invariant: [`weather_data_dbt/tests/sentinel_translation_invariant.sql`](../../weather_data_dbt/tests/sentinel_translation_invariant.sql)
- Upstream decision: [001](001-string-typed-bronze-sentinels.md)
