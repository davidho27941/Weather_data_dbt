# CWA `Precipitation` / `SunShine` semantics fix (PR #11)

## Summary

`dbt-weekly-build` started failing on three `dbt_utils.accepted_range`
tests:

- `precipitation ∈ [0, 200] mm` — 18,497 rows out of range
- `sunshine_duration_10min ∈ [0, 24] h` — 2,693 rows out of range
- `uv_index ∈ [0, 20]` — 12 rows out of range

The thresholds were calibrated on the assumption that O-A0003-001's
`Precipitation` and `SunshineDuration` report values within the past
10-minute bucket. Investigation showed they don't: per the CWA spec
they're **daily-cumulative since Asia/Taipei midnight**, snapshotted
into each 10-min observation. Calling them `precipitation` /
`sunshine_duration_10min` and testing them against 10-min thresholds
was a *semantic* mis-modeling that compiled and ran cleanly — the
weekly job failures are the visible tip; the silent corruption of
the rollup facts (which `SUM` the cumulative column) is the bigger
problem.

This PR rebases the dbt project onto the correct semantics. See
[ADR-004](decisions/004-cwa-precipitation-sunshine-are-daily-cumulative.md)
for the full decision record.

## Reconciliation evidence

Station `72S590` (賓朗果園, 農業雨量站), Asia/Taipei date 2025-09-24:

| Source | Trajectory | Daily total |
|---|---|---|
| BigQuery `fct_measurements_10min.precipitation`, ordered by `measure_at` | 175.5 at 00:00 UTC (= 08:00 Taipei) → monotone ↑ → 343.0 at 16:00 UTC (= 24:00 Taipei) → 0.0 at 16:10 UTC (= 00:10 Taipei next day) | 343.0 mm |
| CWA web-portal hourly CSV for the same station/day, `Precp` column summed across 24 hours | 27.0 + 25.5 + ... + 0.0 | **343.0 mm** |

Identical to the 0.1 mm. The intra-day BigQuery trajectory is the
running cumulative; the post-midnight drop to 0.0 is the next Taipei
day starting fresh. Same pattern for `SunShine` (CSV hourly sunshine
sums to BigQuery daily cumulative endpoint).

CWA's `RainfallElement/Past10Min/Precipitation` field — which would
be a true 10-min window — only exists in `O-A0002`, which the crawler
doesn't consume. So 10-min window values are derived in staging via
LAG-diff, not fetched directly.

## What's wrong, in two flavors

**1. The visible failure: tests miscalibrated.**
`accepted_range [0, 200] mm` against a daily-cumulative column flags
the cumulative end-of-day total at any wet station with > 200 mm in
the day. 18k+ rows fail on every typhoon week. This is the alert
source.

**2. The silent failure: rollup `SUM` is nonsense.**
`measurement_aggregates.sql` did
`SUM(precipitation) AS precipitation_sum` where `precipitation` is
the running daily total. Summing the running total across 10-min
snapshots produces a quadratically-inflated value that has no
physical meaning. Every `precipitation_sum` /
`sunshine_duration_sec` value emitted by
`fct_measurements_hourly` / `daily` / `weekly` / `monthly` since
PR #3 has been wrong. This is the worse bug — silent, downstream,
not flagged by any test.

The fix addresses both.

## Decision (per ADR-004)

Treat O-A0003-001's `Precipitation` and `SunshineDuration` as
**daily-cumulative**, derive the true 10-min window via LAG-diff
partitioned by `(station_id, DATE(measure_at, 'Asia/Taipei'))`, and
expose both columns as dual columns per [ADR-002](decisions/002-dual-column-raw-cleaned-staging.md):

```
precipitation_daily_cumulative_raw         STRING    raw CWA cumulative
precipitation_daily_cumulative             FLOAT64   cleaned cumulative (mm)
precipitation_10min_window                 FLOAT64   LAG-diff derived (mm/10min)

sunshine_duration_daily_cumulative_raw     STRING
sunshine_duration_daily_cumulative         FLOAT64   cleaned cumulative (h)
sunshine_duration_10min_window             FLOAT64   LAG-diff derived (h/10min)
```

Derivation rules baked into the staging SQL:

- **Partition by Asia/Taipei date**, not UTC date — the reset boundary
  is Taipei midnight (= UTC 16:00), not UTC midnight.
- `LAG(... IGNORE NULLS)` so sentinel→NULL gaps don't break differencing
  within a day; a missed obs attributes its increment to the next valid
  bucket rather than to NULL.
- First obs of a Taipei day (no LAG row) → derived value = the
  current cumulative (it's by definition the day's first 10-min total).
- Monotonicity violation (`current < previous` within the day, e.g.
  CWA mid-day correction) → derived value = NULL. Don't fabricate
  negative rainfall.

Rollup facts (`measurement_aggregates` macro) now SUM the derived
window column instead of the cumulative.

## Test threshold rebase

| Column | Range | Severity | Rationale |
|---|---|---|---|
| `precipitation_10min_window` | [0, 200] mm | error | Original threshold; *now* the right column |
| `precipitation_daily_cumulative` | [0, 2500] mm | warn | Taiwan typhoon daily-station record ~1825 mm (Morakot 2009 阿里山); 2500 mm leaves climate headroom |
| `sunshine_duration_10min_window` | [0, 1.5] h | error | Physical max 1.0h/h; 1.5 catches scale-of-10 bugs without false-alarming on a slightly late tick |
| `sunshine_duration_daily_cumulative` | [0, 14] h | warn | Solstice physical max in Taiwan ~14h |
| `uv_index` | [0, 25] | error | Widened from 20 → 25 (observed legitimate noon-summer 21/22 at a handful of stations) |

Net test count: **65 → 67** (replaced 2 misaligned tests with 4 correctly-aligned tests).

## Folded-in fix: `sunshine_duration_sec` → `sunshine_duration_sum`

The rollup output column was named `_sec` (implying seconds), but CWA
O-A0003-001 reports sunshine in **hours**. Pre-existing misnaming.
Since this PR was already touching the macro and all four rollup
facts, the rename is folded in here. New name matches the existing
`precipitation_sum` convention (aggregation-type suffix, not unit
suffix).

## Changes

| File | Change |
|---|---|
| [`weather_data_dbt/models/staging/stg_observations.sql`](../weather_data_dbt/models/staging/stg_observations.sql) | Adds `translated` + `lagged` CTEs; renames `precipitation` / `sunshine_duration_10min` outputs to `*_daily_cumulative*`; emits new `*_10min_window` derived columns |
| [`weather_data_dbt/macros/measurement_aggregates.sql`](../weather_data_dbt/macros/measurement_aggregates.sql) | `SUM` / `MAX` switched from cumulative to `*_10min_window`; sunshine output renamed `_sec` → `_sum` with explicit unit comment |
| [`weather_data_dbt/models/marts/measurements/fct_measurements_10min.sql`](../weather_data_dbt/models/marts/measurements/fct_measurements_10min.sql) | Exposes both dual-column sets (cumulative + window) for precipitation and sunshine; docstring expanded with ADR-004 pointer |
| [`weather_data_dbt/models/marts/measurements/fct_measurements_hourly.sql`](../weather_data_dbt/models/marts/measurements/fct_measurements_hourly.sql) | Reference `sunshine_duration_sum` instead of `sunshine_duration_sec` |
| [`weather_data_dbt/models/marts/measurements/fct_measurements_daily.sql`](../weather_data_dbt/models/marts/measurements/fct_measurements_daily.sql) | Same rename |
| [`weather_data_dbt/models/marts/measurements/fct_measurements_weekly.sql`](../weather_data_dbt/models/marts/measurements/fct_measurements_weekly.sql) | Same rename |
| [`weather_data_dbt/models/marts/measurements/fct_measurements_monthly.sql`](../weather_data_dbt/models/marts/measurements/fct_measurements_monthly.sql) | Same rename |
| [`weather_data_dbt/models/marts/_models.yml`](../weather_data_dbt/models/marts/_models.yml) | 5 `accepted_range` tests rebased (see threshold table above); `fct_measurements_10min` description rewritten to document the dual-column-on-precip/sunshine pattern |
| [`weather_data_dbt/tests/sentinel_translation_invariant.sql`](../weather_data_dbt/tests/sentinel_translation_invariant.sql) | Per-column UNIONs updated to reference the renamed `*_daily_cumulative*` staging columns |
| [`docs/decisions/004-cwa-precipitation-sunshine-are-daily-cumulative.md`](decisions/004-cwa-precipitation-sunshine-are-daily-cumulative.md) | New ADR-004 |
| [`docs/decisions/README.md`](decisions/README.md) | Index gains 004; "Why these four" replaces "Why only three" |
| [`README.md`](../README.md) | PR #11 entry in migration history; PR #8 row notes 004 added later |

`int_measurements__cleaned` and the four rollup fact `SELECT` lists
required no changes beyond the propagated rename — staging's `SELECT *`
forward chain carries the new columns automatically, and the macro
change cascades to all four rollups in one diff.

## Breaking changes for downstream consumers

Anyone reading `fct_measurements_10min.precipitation` or
`fct_measurements_10min.sunshine_duration_10min` directly **will
break**. The rename is deliberate — leaving the old names behind
with silently-changed semantics would be worse. Migration:

| Old reference | New reference |
|---|---|
| `precipitation` | `precipitation_10min_window` for per-bucket use, `precipitation_daily_cumulative` for running totals |
| `precipitation_raw` | `precipitation_daily_cumulative_raw` |
| `sunshine_duration_10min` | `sunshine_duration_10min_window` for per-bucket, `sunshine_duration_daily_cumulative` for running |
| `sunshine_duration_10min_raw` | `sunshine_duration_daily_cumulative_raw` |
| Rollup `sunshine_duration_sec` | `sunshine_duration_sum` (unit unchanged: hours) |
| Rollup `precipitation_sum` | Same name, but value is now correct (was nonsense quadratic) |

There are no known internal downstream consumers reading these
columns today; the marts dataset is the contract boundary and no ML
training is wired up yet. Future-proofing for [ADR-003](decisions/003-enforce-dbt-contracts-on-marts.md)
(marts contract enforcement) is what makes the breaking rename safer
than leaving the old names in place.

## Test plan

- [x] `dbt parse` clean
- [x] `dbt compile` clean — 11 models, 67 data tests, 0 errors / warnings
- [x] `sentinel_translation_invariant` compile output inspected;
      sentinel families and renamed column references all line up
- [x] `measurement_aggregates` compile output verified to SUM
      `*_10min_window`, not cumulative
- [ ] **Manual verification (post-merge or on dev target):**
      `dbt build --select +fct_measurements_10min --target dev`,
      then re-run the reconciliation query against
      `fct_measurements_10min.precipitation_10min_window` for
      `station_id='72S590'` on Taipei date 2025-09-24 — the per-hour
      sums must match the CWA CSV `Precp` column row-for-row.
- [ ] **Weekly job dry run:** trigger
      `dbt-weekly-build` Cloud Run Job once after merge to confirm
      `PASS=N WARN=N ERROR=0`. The relationships warnings for
      decommissioned stations (`severity: warn`, per pre-existing
      design) will still appear; they're orthogonal to this PR.

## Out of scope

- **Crawling O-A0002 for native `Past10Min/Precipitation`.** Discussed
  in ADR-004's Alternatives section and rejected for now; the
  derivation is unavoidable for the O-A0003 stations anyway, so a
  second feed is not worth the operational cost. Revisit if 自動雨量站
  coverage gaps surface a real consumer need.
- **Backfilling rollup tables.** The cumulative-SUM corruption in
  hourly/daily/weekly/monthly is a year+ old. After this PR merges,
  the incremental MERGE windows will rewrite the last
  `measurements_lookback_days = 10` days of hourly/daily; weekly and
  monthly are full-table materializations and will rebuild from
  scratch. A one-time
  `dbt build --full-refresh --select fct_measurements_hourly fct_measurements_daily`
  is the cleanest way to repair historical rollup rows; queued for
  ops to run post-merge.
- **`docs/redesign_proposal.md` updates.** That doc is a
  pre-implementation design snapshot (per its own opening note), not
  living documentation; references to `sunshine_duration_sec` and the
  pre-cumulative-fix macro are intentionally preserved as the
  proposal's original form. Promoting it to an archive doc is a
  separate cleanup.
- **`dim_stations` geo metadata for `rain_fall` stations.** During
  investigation we discovered a separate bug — the crawler's `agri`
  case used the wrong URL constant, so `rain_fall` station
  longitude/latitude/county info in `dim_stations` is currently
  unreliable. Crawler-side fix landed in a separate commit; backfill
  of `dim_stations` rain_fall geo is its own follow-up PR.

## References

- ADR-004:
  [`docs/decisions/004-cwa-precipitation-sunshine-are-daily-cumulative.md`](decisions/004-cwa-precipitation-sunshine-are-daily-cumulative.md)
- ADR-002 (dual-column pattern this PR continues to follow):
  [`docs/decisions/002-dual-column-raw-cleaned-staging.md`](decisions/002-dual-column-raw-cleaned-staging.md)
- ADR-001 (bronze stays a faithful CWA mirror — the column rename is
  staging-layer-only):
  [`docs/decisions/001-string-typed-bronze-sentinels.md`](decisions/001-string-typed-bronze-sentinels.md)
- CWA O-A0003-001 spec:
  `//Station/WeatherElement/Now/Precipitation` (daily cumulative, mm),
  `//Station/WeatherElement/Now/SunshineDuration` (daily cumulative, h)
- Crawler entry point that consumes O-A0003-001:
  [`weather-crawler/weather_crawler/api.py`](../weather-crawler/weather_crawler/api.py)
- Runbook reference for re-running the Cloud Run Job after a fix:
  [`docs/runbook.md`](runbook.md) §3
- Branch: `feat/cwa-cumulative-semantics-fix` → `main`
