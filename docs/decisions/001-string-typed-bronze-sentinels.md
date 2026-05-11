# STRING-typed bronze observations preserve CWA sentinels

## Status

Accepted

## Date

2026-05-09 (PR #2)

## Context

CWA's O-A0003-001 observation feed encodes "missing", "invalid", and
"semantic" values inline as magic strings rather than as a separate
quality flag:

| Sentinel | Meaning |
|---|---|
| `'X'` | instrument malfunction |
| `'-99'` / `'-999'` | missing / abnormal |
| `'T'` | trace precipitation (too small to measure → semantically 0) |
| `'-98'` | "no rain in past 6 hours" (precipitation → semantically 0) |
| `'990'` | calm wind (`wind_direction` only — no defined direction) |

The same field can carry numeric data, "missing" sentinels, and (for
precipitation) "semantic zero" sentinels. Information loss happens if
they're all collapsed to NULL at ingest:

- Governance / debugging cannot distinguish "instrument broken" from
  "no rain measured" from "we don't know".
- ML training cannot decide its own NULL policy for trace
  precipitation (sometimes 0 is the right answer, sometimes NULL is).
- Re-deriving bronze from GCS becomes the only way to recover the
  original encoding.

## Decision

Store the entire measurement payload as **STRING-typed at bronze**.
`weather_raw.observations` carries every measurement field as STRING,
with the raw CWA value verbatim, sentinels included.

Sentinel translation is a **staging-layer concern** (see
[002](002-dual-column-raw-cleaned-staging.md) and the
`cwa_string_to_float` macro). Bronze is a faithful, lossless mirror of
the CWA payload.

## Alternatives considered

- **NULL out sentinels at ingest.** Simpler downstream but lossy.
  Trace precipitation collapses to NULL (wrong — semantically it's
  0); '-98' (no rain past 6h) is indistinguishable from real missing
  data. Hard to recover after the fact.
- **FLOAT64 fields + parallel `<field>_sentinel` STRING column.**
  Doubles the column count at bronze (similar to the staging
  dual-column pattern in [002](002-dual-column-raw-cleaned-staging.md))
  but moves the translation logic upstream. We chose to keep bronze
  as a literal mirror so the staging macro is the single source of
  truth for translation rules.
- **JSON-typed payload.** Preserves everything but pushes parsing cost
  onto every downstream query. BQ STRING-vs-JSON storage cost is the
  same; the query cost isn't.

## Consequences

- **Easier:** bronze is byte-for-byte reproducible from the GCS source
  files; sentinel rule changes are a single-file diff in
  `cwa_string_to_float`; governance audit can query the unmodified
  raw value.
- **Harder:** staging is non-trivial (one macro, ~50 lines, handles
  three different sentinel families); type narrowing happens at
  staging instead of bronze, so downstream `SELECT *` against bronze
  gets STRINGs even for fields that are "really" floats.
- **Watch out for:** schema-on-read at staging means a new measurement
  field that the macro doesn't know about will silently pass through
  as a string. Mitigated by the `sentinel_translation_invariant` test
  (PR #7) which fails the build if a non-sentinel raw value produces a
  NULL cleaned value.

## References

- Translation macro: [`weather_data_dbt/macros/cwa_string_to_float.sql`](../../weather_data_dbt/macros/cwa_string_to_float.sql)
- Staging consumer: [`weather_data_dbt/models/staging/stg_observations.sql`](../../weather_data_dbt/models/staging/stg_observations.sql)
- Dual-column pattern enforced downstream: [002](002-dual-column-raw-cleaned-staging.md)
