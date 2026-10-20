# Cost and performance — weather pipeline

Notes on what we currently spend, what choices drive it, what to do if
costs spike, and what cost-relevant signals to expect on the
pipeline-health dashboard.

Estimates are derived from observed CI activity (Q2 2026) plus
hand-calculation against the project's actual cadence. Refresh
annually or after a meaningful volume change (e.g. CWA endpoint
expansion, new fact granularity, multi-region replication).

Last reviewed: 2026-05-11.

## Annual cost ballpark

| Component | Est. cost / year | Primary driver |
|---|---|---|
| BigQuery on-demand queries | < $1 | weekly `dbt build` + daily MERGE + hourly freshness |
| BigQuery active + long-term storage | < $1 | marts ~3 GiB after first year |
| GCS Standard + tiered lifecycle | < $1 | crawler JSON tiered to Archive within 365d |
| Cloud Run Job compute | < $1 | three Jobs, mostly idle |
| Cloud Scheduler | $0 | 3 jobs under free-tier (3 jobs free) |
| Artifact Registry | < $1 | ~500 MiB of images |
| Cloud Monitoring + Logging | $0 | within free tier; 30d retention |
| **Total** | **~$5–10 / year** | Side-project scale |

The total is dominated by minimum per-resource markups, not by data
volume. A 10× data increase wouldn't push this past ~$20/year because
the dominant cost categories are already near floor pricing.

## What drives each line

### BigQuery on-demand queries

Pricing: $5/TiB scanned (no reservation; on-demand only).

Observed (Q2 2026, CI 7-day subsample):
- `int_measurements__cleaned`: ~60 MiB scanned per build
- `fct_measurements_10min`: ~68 MiB
- Other 4 fct + dim_stations: ~17 MiB each ⇒ ~85 MiB combined
- All tests: ~5 MiB per test × 80 tests ⇒ ~400 MiB

Weekly `dbt build` total scan ≈ **600 MiB** ⇒ **$0.003 / build** ⇒
**$0.16 / year** at 52 weekly builds.

Daily bronze MERGE scans yesterday's GCS files + a 7-day lookback on
existing rows. Estimated ~150 MiB / day × 365 ⇒ ~55 GiB / year ⇒
**$0.27 / year**.

Hourly dbt source freshness is effectively a `MAX(ingest_at)` against
the bronze table. < 1 MiB per run × 8760 runs ⇒ < 9 GiB / year ⇒
**$0.04 / year**.

**BQ query total: ~$0.50 / year** at current cadence.

### BigQuery storage

Pricing: $0.020/GiB/month active, $0.010/GiB/month after 90 days no
edits. Long-term storage is automatic.

Sized at full population (~5 years of CWA data, ~16M rows/year):
- `weather_raw.observations`: ~3 GiB / year × 5 years partitioned
- `weather_marts.*`: similar scale across 5 fct + 1 dim
- After year 2+, most partitions hit long-term storage tier

Steady-state storage cost: **< $1 / year** total across all datasets.

### GCS — crawler bucket

Pricing (asia-east1):
- Standard: $0.020 / GiB / month
- Nearline: $0.010 / GiB / month
- Coldline: $0.004 / GiB / month
- Archive: $0.0012 / GiB / month

Crawler writes ~6 JSON files / 10 min × ~5 KiB each ⇒ ~430 MiB / month
of raw payloads. With the tiered lifecycle (PR #6: Standard → Nearline
30d → Coldline 90d → Archive 365d), after one year:
- ~430 MiB in Standard (0-30d)
- ~870 MiB in Nearline (30-90d)
- ~3.9 GiB in Coldline (90-365d)
- Eventually all old data in Archive

Steady-state blended cost: **~$0.10 / month** ⇒ **~$1.20 / year**.

### Cloud Run Job compute

Pricing: $0.00002400 / vCPU-second + $0.00000250 / GiB-memory-second
when actively running.

At 1 vCPU + 2 GiB memory, ~$0.0000290/sec ⇒ ~$0.10 per hour of runtime.

Observed runtimes:
- `bronze-daily-load`: ~30s / run × 365 = ~3h / year
- `dbt-weekly-build`: ~5min / run × 52 = ~4.3h / year
- `dbt-hourly-freshness`: ~10s / run × 8760 = ~1h / year

Total: ~8.3h / year × $0.10/h = **~$0.85 / year**.

## Materialisation choices and why

Decisions that drive both cost and rebuild speed:

| Model | Materialisation | Reasoning |
|---|---|---|
| `stg_observations` | `view` | Source is bronze STRING-typed; rebuild is free, no need to materialise. Pushdown filters the heavy bronze partition scans down through the view at query time. |
| `stg_weather_stations`, `stg_rain_fall_stations` | `view` | Tiny dimensions, no benefit to materialising. |
| `int_measurements__cleaned` | `incremental` (`merge`, `unique_key=[station_id, measure_at]`) | Re-cleaning all rows weekly is wasteful for historical data that already passed sentinel translation. Lookback window absorbs late-arriving snapshots. |
| `int_stations__unioned` | `table` | Tiny (~1.5k rows), full-refresh is fine. |
| `dim_stations` | `table` | Always reflects the latest CWA station snapshot. Per-row history is not needed; the source is itself a "latest" snapshot. |
| `fct_measurements_10min` | `incremental` (`merge` on `[station_id, measure_at]`, partitioned by day) | Largest fact; full refresh would scan all historical data. Incremental with day-partitioned MERGE only touches the lookback window. |
| `fct_measurements_{hourly,daily}` | `incremental` (same shape) | Same logic — incremental aggregations on day-partitioned source. |
| `fct_measurements_{weekly,monthly}` | `table` | Cardinality is so low (~700 rows/year per grain) that full refresh is cheaper than the operational complexity of incremental at this size. |

Pattern: incremental where the table is partitioned-by-day and the
volume justifies it; table where it doesn't.

## Partition and cluster strategy

Set on every fact:

```hcl
partition_by = {'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'day'}
cluster_by   = ['station_id', 'station_type']
```

The day-partition is what makes MERGE cheap — BQ's MERGE planner only
reads the partitions matched by the source-side filter, which is the
`measure_at >= TIMESTAMP_SUB(..., INTERVAL N DAY)` lookback. Without
this, every MERGE would full-scan the destination.

Cluster on `(station_id, station_type)` because virtually every
downstream query filters by station_id (per-station ML training) and
station_type (filter to manned stations to drop NULL-sensor rows). The
clustering moves rows for the same station physically adjacent within
each partition; query pruning eliminates 90%+ of irrelevant blocks.

Not clustered on `measure_at` — it's already the partition key, and BQ
documentation explicitly recommends *not* clustering on the partition
column.

## Levers if costs spike

In rough order of "how much cost the lever moves" vs "how disruptive
the change":

1. **Tighten `measurements_lookback_days`** (currently 7). Halving it
   halves the MERGE scan volume. Trade-off: late-arriving CWA snapshots
   beyond the window get dropped — a real risk only if crawler is down
   > 3 days.

2. **Switch CI from `dbt build --target ci` to selective testing.** CI
   currently builds the full DAG against a 7-day bronze sample. Could
   restrict to changed models via `state:modified+ -- 1` once we have
   manifest comparison in place. Saves ~80% of CI BQ scan.

3. **Drop weekly cadence to bi-weekly.** Halves dbt-weekly-build cost.
   Trade-off: marts freshness target (currently 14d in `docs/slo.md`)
   becomes tight.

4. **Materialise the heavy stg view.** If `stg_observations` view ends
   up scanned multiple times per build (e.g. by future downstream
   models that don't share the cleaned int), promote it to table.

5. **BigQuery slot reservation.** Only worth considering above ~$300 /
   year on-demand spend. We're 60× below that, and reservations carry
   their own minimum commit; not relevant unless data volume grows 50×.

6. **Compress / batch crawler outputs.** Each 10-min run currently
   writes 6 small JSON files. If small-object operation costs become
   noticeable, switch to per-hour concatenation. Currently they don't.

## Observability for cost

Dashboard panel `BigQuery — billable bytes scanned (per hour)` on
`Weather pipeline health` shows the marginal-cost signal directly.

Multiply by the on-demand rate to estimate spend:

```
$ / hour ≈ (billable_bytes_per_hour) × (1 TiB / 1.1e12 bytes) × $5
        ≈ billable_bytes_per_hour × 4.5e-12
```

A 10× spike from typical (a few GiB/h) sustained over 24h is the
threshold where a follow-up is justified. The dashboard panel is
configured to fail gracefully (`ALIGN_DELTA`, 1h alignment) so spikes
are easy to read directly off the bars.

GCS object growth and lifecycle transitions are visible on the
`Crawler bucket — bytes by storage class` panel; a step change in
total bytes (e.g. crawler stuck writing larger payloads) shows there
before the storage bill arrives.

## Out of scope

- Reservation-based BigQuery pricing analysis. Only meaningful at
  ~50× current volume.
- Per-query attribution / chargeback. Single-tenant project; not
  needed.
- Cross-region replication cost. Single-region (`asia-east1`) by
  design; no replication.
- `weather_dev_*` and `weather_ci_*` datasets. Created on demand by
  individual developer / CI runs and dropped between runs; their
  storage cost is negligible.

## References

- BigQuery on-demand pricing: <https://cloud.google.com/bigquery/pricing#analysis_pricing_models>
- BigQuery storage pricing: <https://cloud.google.com/bigquery/pricing#storage>
- GCS storage classes: <https://cloud.google.com/storage/pricing>
- Cloud Run Job pricing: <https://cloud.google.com/run/pricing#tables>
- Dashboard panel definitions: [`terraform/observability.tf`](../terraform/observability.tf)
- SLO targets (freshness drives cadence drives cost): [`docs/slo.md`](slo.md)
