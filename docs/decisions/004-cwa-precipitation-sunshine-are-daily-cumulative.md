# CWA `Precipitation` and `SunShine` are daily-cumulative, not 10-min windows

## Status

Proposed

## Date

2026-05-26 (PR #11)

## Context

The weekly `dbt-weekly-build` Cloud Run Job started failing with three `dbt_utils.accepted_range` test errors:

- `precipitation ∈ [0, 200] mm` — 18,497 rows out of range
- `sunshine_duration_10min ∈ [0, 24] h` — 2,693 rows out of range
- `uv_index ∈ [0, 20]` — 12 rows out of range

The thresholds were chosen on the assumption — encoded across the staging macro, the marts column descriptions, and the `_models.yml` test rationales — that O-A0003-001's `Precipitation` and `SunShine` fields report **the amount observed within the past 10-minute bucket** (10-min window). At those volumes 18k rows beyond 200 mm / 10 min is physically impossible (10-min world record ~38 mm; the values we see extend to 660+ mm), so the assumption had to be wrong.

The actual semantics are different. Per the CWA O-A0003-001 spec, the relevant JSON paths are:

```
//Station/WeatherElement/Now/Precipitation       — 當日累計降水量 (mm)
//Station/WeatherElement/Now/SunshineDuration    — 當日累計日照時數 (hour)
```

These are **cumulative since local (Asia/Taipei) midnight**. They reset at 00:00 Asia/Taipei, monotonically increase across the day, and the value snapshotted at any 10-min observation is the running daily total at that moment — not the increment within that bucket.

### Reconciliation evidence

Station `72S590` (賓朗果園, 農業雨量站), Asia/Taipei date 2025-09-24:

| Source | Trajectory | Daily total |
|---|---|---|
| BigQuery `fct_measurements_10min.precipitation`, ordered by `measure_at` | 175.5 at 00:00 UTC (= 08:00 Taipei) → monotone ↑ → 343.0 at 16:00 UTC (= 24:00 Taipei) → 0.0 at 16:10 UTC (= 00:10 Taipei next day) | 343.0 mm |
| CWA web-portal hourly CSV for the same station/day, `Precp` column summed across 24 hours | 27.0 + 25.5 + ... + 0.0 | **343.0 mm** |

The two datasets reconcile **exactly to the 0.1 mm**. The intra-day BigQuery trajectory is the running cumulative; the post-midnight drop to 0.0 is the next Taipei day starting from zero. The same pattern holds for `SunShine` (CSV hourly sunshine sums to BigQuery daily cumulative endpoint).

CWA's `RainfallElement/Past10Min/Precipitation` field — which *would* be a true 10-min window — exists in `O-A0002` (自動雨量站), but is not in `O-A0003-001`. The crawler ([`weather-crawler/weather_crawler/api.py`](../../weather-crawler/weather_crawler/api.py)) only consumes `O-A0003-001`, so 10-min window values are not available from the source. They have to be **derived**.

### Downstream impact

The mis-modeling has propagated to two places that matter:

1. **`_models.yml` accepted_range tests.** Testing the cumulative value against a 10-min threshold produces noisy `severity: error` failures on every typhoon day. This is the immediate alert source.
2. **The rollup facts** (`fct_measurements_hourly` / `daily` / `weekly` / `monthly`) `SUM` the cumulative column when computing per-bucket precipitation. Summing a running daily total across 10-min snapshots produces nonsense — the rollup `precipitation` numbers are systematically wrong, by a factor that grows quadratically through each day. This is silent and worse than the alert.

## Decision

Treat `Precipitation` and `SunShine` from O-A0003-001 as **daily-cumulative** in staging, and **derive** true 10-min window values via LAG-diff within each Asia/Taipei day. Expose both as dual columns per [ADR-002](002-dual-column-raw-cleaned-staging.md):

```
precipitation_daily_cumulative_raw         STRING    raw CWA value (rename of precipitation_raw)
precipitation_daily_cumulative             FLOAT64   cleaned cumulative (rename of precipitation)
precipitation_10min_window                 FLOAT64   derived: current - previous within Taipei day

sunshine_duration_daily_cumulative_raw     STRING
sunshine_duration_daily_cumulative         FLOAT64
sunshine_duration_10min_window             FLOAT64   derived
```

Derivation rules:

- Window: `PARTITION BY station_id, DATE(measure_at, 'Asia/Taipei') ORDER BY measure_at`.
- `LAG(... IGNORE NULLS)` so sentinel→NULL gaps don't break differencing within a day; a single bad observation attributes its missed increment to the next valid bucket rather than to NULL.
- First observation of each Taipei day (no previous row in partition) → derived value = current cumulative (the very first 10-min snapshot is by definition the full window).
- Monotonicity violation (`current < previous`, e.g. mid-day CWA correction or clock skew) → derived value = NULL. Don't fabricate negative rainfall.

The bronze layer **does not change**. The bronze column is still named `precipitation` (because it mirrors the CWA payload field name, per [ADR-001](001-string-typed-bronze-sentinels.md)); the rename happens only at the staging boundary where semantic naming starts to matter for downstream consumers.

Tests in `_models.yml` are rebased onto the derived columns:

- `precipitation_10min_window ∈ [0, 200] mm` — `severity: error`. The original 200 mm 10-min threshold is *now* the right one for this column.
- `precipitation_daily_cumulative ∈ [0, 2500] mm` — `severity: warn`. Taiwan typhoon daily station record is ~1825 mm (Morakot 2009 at 阿里山); 2500 leaves enough headroom for a climate-shifted future where the historical record gets exceeded without re-tuning the alert.
- `sunshine_duration_10min_window ∈ [0, 1.5] h` — `severity: error`. Physical max is 1.0 h per hour; 1.5 catches scale-of-10 bugs without false-alarming on a slightly-late tick.
- `sunshine_duration_daily_cumulative ∈ [0, 14] h` — `severity: warn`. Solstice physical max in Taiwan ~14 h.

Rollup facts switch from `SUM(precipitation_daily_cumulative)` to `SUM(precipitation_10min_window)` — the only correct way to total precipitation across a bucket. `SUM(sunshine_duration_10min_window)` likewise.

## Alternatives considered

- **Widen the test thresholds, leave the column as-is.** Smallest diff. Stops the alert. Does not fix the silent rollup bug — `SUM(cumulative)` is still wrong regardless of the test threshold. Rejected: the alert is the symptom, the SUM is the disease.

- **Crawl O-A0002 separately and join in `Past10Min/Precipitation`.** Gets the "correct" 10-min value from CWA directly without derivation, for the subset of stations O-A0002 covers (自動雨量站 only). Even with O-A0002 in hand, the manned and automatic CWA weather stations in O-A0003 would still need the LAG-diff derivation — so this only saves work for a subset of stations while adding a second source feed, a second parsing path, and overlap-reconciliation logic for stations that appear in both. Rejected: out of scope for the current build, and the derivation is unavoidable for the O-A0003-only stations anyway. If O-A0002 ingestion becomes desirable later for an independent reason (e.g. 自動雨量站 stations that aren't in O-A0003, or a need for sub-10-min cadence), revisit then.

- **Rename in bronze too.** Bronze column becomes `precipitation_daily_cumulative` literally. Matches semantics end-to-end. Rejected: [ADR-001](001-string-typed-bronze-sentinels.md) commits bronze to being a faithful CWA payload mirror; renaming the column there breaks that invariant for a single field's convenience. Semantic naming belongs at the staging boundary.

- **Compute the 10-min window only at the consumer.** Hand consumers the cumulative and let ML pipelines compute their own LAG-diff. Pushes the logic — and the responsibility for getting Asia/Taipei date partitioning and `IGNORE NULLS` and the monotonicity-violation handling right — onto every downstream user. Rejected: this is exactly the "translate sentinels at every consumer" anti-pattern [ADR-001](001-string-typed-bronze-sentinels.md) and [ADR-002](002-dual-column-raw-cleaned-staging.md) rejected.

- **Drop the cumulative columns from `fct_measurements_10min`, expose only the derived 10-min value.** Smallest schema. Rejected: violates [ADR-002](002-dual-column-raw-cleaned-staging.md) dual-column principle. The cumulative value is non-derivable from the 10-min value alone (mid-day NULL gaps lose information), so discarding it means governance/debug cannot answer "what was the running total at this snapshot?" without re-querying bronze. Keep both.

## Consequences

- **Easier:** `accepted_range` tests test what they claim to test (10-min values against 10-min thresholds); rollup `precipitation` and sunshine totals are correct; downstream ML pipelines that want per-bucket precipitation get a single, clearly-named column; the dual-column pattern lets governance reconstruct the cumulative trajectory from `fct_measurements_10min` alone without re-querying bronze.

- **Harder:** staging gains a window function and a CTE around it; the `_10min` fact widens by two columns; consumers reading the old `precipitation` / `sunshine_duration_10min` columns must update to the renamed/derived columns (the rename is breaking on purpose — leaving the old name behind silently changing semantics would be worse).

- **Watch out for:**
  - **Incremental MERGE windows must cover at least one Taipei day** so LAG within partition has its previous row. The current `measurements_lookback_days = 5` is comfortably enough; if it ever drops below 1 the derivation at the partition boundary breaks.
  - **Asia/Taipei date partitioning is mandatory.** Using UTC date instead would put the reset at 08:00 Taipei (the wrong moment) and corrupt the entire derivation. Reviewers should check the `DATE(measure_at, 'Asia/Taipei')` is present and explicit.
  - **Backfill behavior on `--full-refresh`.** Because the derivation needs the full partition to compute, a full-refresh recomputes correctly from bronze without any extra state. No `_state` table needed. But a *partial* refresh (e.g. selecting just the last 6 hours) will produce a NULL at the first row of that partial window because LAG has nothing to look back at — this is fine for re-running the full incremental window, surprising for ad-hoc partial selects. Documented at the model level rather than worked around.
  - **A new field with similar semantics** (e.g. CWA adds a new "cumulative" weather element in a future spec revision) needs the same LAG treatment, not just a column-list change. The `sentinel_translation_invariant` test catches sentinel-mapping mistakes but not semantics-mapping mistakes; reviewers of CWA-spec-driven changes need to ask "is this a window value or a running total?" explicitly.

## References

- Reconciliation evidence: BigQuery query result for station `72S590` on 2025-09-24 (captured in PR description) vs. CWA web-portal hourly CSV (`72S590-2025-09-24.csv`)
- CWA O-A0003-001 spec: `//Station/WeatherElement/Now/Precipitation` (daily cumulative), `//Station/WeatherElement/Now/SunshineDuration` (daily cumulative)
- Crawler source: [`weather-crawler/weather_crawler/api.py`](../../weather-crawler/weather_crawler/api.py) (consumes `O-A0003-001` only)
- Staging derivation lands in: [`weather_data_dbt/models/staging/stg_observations.sql`](../../weather_data_dbt/models/staging/stg_observations.sql)
- Test rebase lands in: [`weather_data_dbt/models/marts/_models.yml`](../../weather_data_dbt/models/marts/_models.yml)
- Rollup fix lands in: [`weather_data_dbt/models/marts/measurements/`](../../weather_data_dbt/models/marts/measurements/) (hourly / daily / weekly / monthly)
- Bronze stays a faithful CWA mirror per: [ADR-001](001-string-typed-bronze-sentinels.md)
- Dual-column pattern at staging per: [ADR-002](002-dual-column-raw-cleaned-staging.md)
- Marts contract enforcement (related, not blocked by): [ADR-003](003-enforce-dbt-contracts-on-marts.md)
