# Runbook — backfill and recovery

Step-by-step recipes for the incident classes we plausibly encounter,
written so the response under stress isn't "improvise from scratch."

The pipeline is heavily idempotent by design — bronze MERGE on
`(station_id, measure_at)`, dbt incremental MERGE on the same key, GCS
hive partitioning by `dt=YYYY-MM-DD`. The default response to almost
everything below is **"re-run the layer that failed"**, not "kick off
a custom backfill." This doc enumerates when that holds, when it
doesn't, and the commands.

Last reviewed: 2026-05-11.

## How to triage

Email alert arrives. First two questions, in order:

1. **Which alert fired?**
   - `Cloud Run Job — execution failed` → infra / runtime issue
     (OOM, network, auth, missing dep). Doesn't necessarily mean data
     is wrong.
   - `dbt test — assertion failed` → a `severity=error` test broke.
     Data correctness is violated *and* the Job ran to completion.
     The two alerts can fire together for the same incident.

2. **Which Job?**
   ```bash
   gcloud run jobs executions list --region=asia-east1 --limit=10 \
     --format='table(name,job:label=JOB,status.startTime,status.completionTime,status.failedCount,status.succeededCount)'
   ```

   - `bronze-daily-load` → §1
   - `dbt-weekly-build` → §3
   - `dbt-hourly-freshness` → §4

Always look at the most recent execution before assuming. The alert
auto-closes after 24h; a closed alert doesn't mean the underlying
state is good.

## §1 — Crawler outage

The crawler is a Cloud Run service triggered by Cloud Scheduler every
10 minutes. Failure modes:

### Symptom A: dbt source freshness WARN / ERROR

Freshness fires when `MAX(ingest_at)` on `weather_raw.observations`
exceeds 36h (WARN) or 72h (ERROR). The freshness Job's exit status
maps `WARN → exit 0`, `ERROR → exit 1` — so an alert from the
freshness Job means error-tier breach (> 72h).

Diagnose:

```bash
# Is the crawler service healthy?
gcloud run services describe weather-crawler --region=asia-east1 \
  --format='value(status.conditions[0].type,status.conditions[0].status)'

# Recent Scheduler invocations (every 10 min — gaps mean failed triggers)
gcloud scheduler jobs list --location=asia-east1 \
  --filter='name~weather-crawler' --format=yaml

# Recent crawler logs
gcloud logging read 'resource.type="cloud_run_revision"
  AND resource.labels.service_name="weather-crawler"
  AND severity>=ERROR' --limit=10 --freshness=24h
```

### Symptom B: GCS objects stop arriving but service looks healthy

```bash
# How recent is the latest crawler file?
gcloud storage ls -l 'gs://side-project-weather-data/**' \
  --recursive --format='value(name,createTime)' | sort -k2 | tail -5
```

If the bucket has gaps but Cloud Run logs show 200s, the issue is
likely the Cloud Scheduler trigger or a permission regression on the
crawler's GCS write SA. Check Scheduler execution history.

### Recovery

- **Short outage (< 24h)**: no action. Next `bronze-daily-load` run
  (02:00 Asia/Taipei) picks up whatever made it to GCS during the
  window. Missing 10-min slices stay missing — re-fetching from CWA's
  historical API is out of scope.

- **Long outage (24h – 7d)**: `bronze-daily-load`'s default lookback
  is 7 days, so as long as crawler comes back within a week, the next
  daily run absorbs all queued files. Verify after the next run:
  ```bash
  bq query --use_legacy_sql=false --location=asia-east1 \
    'SELECT DATE(measure_at) AS day, COUNT(*) AS n
     FROM `side-project-staging.weather_raw.observations`
     WHERE measure_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 14 DAY)
     GROUP BY day ORDER BY day DESC'
  ```
  Expect ~144 × N_stations rows per day under healthy conditions.

- **Long outage (> 7d)**: widen the lookback for one manual run:
  ```bash
  gcloud run jobs execute bronze-daily-load --region=asia-east1 \
    --update-env-vars=LOOKBACK_DAYS=30 --wait
  ```
  Then revert the env var via `terraform apply` (or wait for next CD
  push). One-time elevation, not a permanent change.

## §2 — Bronze MERGE failure (`bronze-daily-load`)

The MERGE is idempotent by `(station_id, measure_at)`. Re-running is
the default response.

### Diagnose

```bash
# Last 5 executions
gcloud run jobs executions list \
  --job=bronze-daily-load --region=asia-east1 --limit=5

# Logs from the latest failed execution
gcloud logging read 'resource.type="cloud_run_job"
  AND resource.labels.job_name="bronze-daily-load"
  AND severity>=ERROR' --limit=20 --freshness=1d \
  --format='value(timestamp,textPayload)'
```

Common failure modes:

- **`Cannot read GCS files`**: SA permission regression on
  `bronze-loader`. Confirm with `gcloud storage buckets get-iam-policy
  gs://side-project-weather-data | grep bronze-loader`. Re-apply
  `terraform apply` if drifted.
- **`MERGE ... must match at most one source row`**: source-side
  duplicates broke through the `ROW_NUMBER` dedup. Inspect the offending
  partition; usually means two crawler invocations produced overlapping
  files for the same `(station_id, measure_at)`. Manually dedup the
  source layer or widen the dedup window in `daily_load.sql`.
- **`Resources exceeded ...`**: bronze MERGE hit a BQ slot limit on
  on-demand pricing. Rare. Re-run is usually enough.

### Recover

Default — just re-run:

```bash
gcloud run jobs execute bronze-daily-load --region=asia-east1 --wait
```

If multiple days missed:

```bash
# Widen the window for one run
gcloud run jobs execute bronze-daily-load --region=asia-east1 \
  --update-env-vars=LOOKBACK_DAYS=14 --wait
```

Verify by row count per day (same query as §1 above).

## §3 — dbt weekly build failure (`dbt-weekly-build`)

dbt build runs the full DAG with `--select +marts`. The DAG has 11
models and ~65 tests; a single error-severity test failure fails the
whole Job.

### Diagnose

```bash
gcloud run jobs executions list \
  --job=dbt-weekly-build --region=asia-east1 --limit=3

# Pull the summary line — usually the last few hundred lines of the log
gcloud logging read 'resource.type="cloud_run_job"
  AND resource.labels.job_name="dbt-weekly-build"
  AND (textPayload=~"FAIL " OR textPayload=~"Done\." OR severity>=ERROR)' \
  --limit=50 --freshness=2d --format='value(timestamp,textPayload)' \
  | tac
```

Look for the `Done. PASS=N WARN=N ERROR=N ...` summary and any
`Failure in test ...` blocks. The `dbt_test_failure_count` log-based
metric is what fired the alert; the dashboard panel `dbt test failures
(severity=error)` shows the count over time.

### Recover

For each failure class:

#### (a) Single test failure, data is genuinely wrong

Don't auto-rerun. Investigate the underlying data:

```bash
# Re-run just the affected test against the live stg dataset
dbt test --select <test_name> --target stg --profiles-dir profiles
```

If the test is wrong (e.g. the `sunshine_duration` bug we hit in
PR #7), fix the test + push + let CD re-roll. If the data is wrong,
the bug is upstream — investigate `int_measurements__cleaned` or
bronze before re-running dbt.

#### (b) Single model SQL error

dbt build stops at the first SQL error; downstream models skip. To
re-run after fixing:

```bash
# Run just the broken model + everything downstream of it
gcloud run jobs execute dbt-weekly-build --region=asia-east1 \
  --update-env-vars="DBT_ARGS=run --select <model_name>+" --wait
```

(Whether this works depends on the Cloud Run Job's entrypoint;
fallback is to wait for the next weekly run after CD pushes the fix.)

#### (c) Incremental state divergence

Symptom: rows look duplicated or missing in marts after a partial
build / mid-build crash. The fix is to full-refresh just the affected
incremental model:

```bash
gcloud run jobs execute dbt-weekly-build --region=asia-east1 \
  --update-env-vars="DBT_ARGS=build --select fct_measurements_10min --full-refresh" --wait
```

**Caveats on `--full-refresh`**:

- Drops and recreates the table. The `partition_by` config preserves
  data semantics but during the rebuild window the table is empty.
- For `fct_measurements_10min` at full volume (~16M rows/year × N
  years), full-refresh takes minutes and scans the entire `int`
  source. Cost-wise still small, but it's the largest cost event
  possible in this pipeline.
- **Never full-refresh during business hours if anyone is querying
  the marts.** No-one is today, but the policy is the policy.

#### (d) OOM / Job runtime exceeded

Cloud Run Job has a 1h default execution timeout. Symptoms: Job
killed without dbt summary line.

```bash
# Bump memory to 4 GiB and re-run
gcloud run jobs update dbt-weekly-build --memory=4Gi --region=asia-east1
gcloud run jobs execute dbt-weekly-build --region=asia-east1 --wait
```

After verifying, revert via `terraform apply` to keep the spec
authoritative.

## §4 — Hourly freshness failure (`dbt-hourly-freshness`)

This Job only runs `dbt source freshness`. The most common cause of
failure is **expected**: a 36h-72h stale source produces WARN, > 72h
produces ERROR (and the Job exits 1).

### Distinguish "expected" from "actual"

```bash
# Most recent ingest_at — tells you which layer broke
bq query --use_legacy_sql=false --location=asia-east1 \
  'SELECT MAX(ingest_at) AS latest, TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingest_at), HOUR) AS hours_stale
   FROM `side-project-staging.weather_raw.observations`'
```

- `hours_stale < 36` → freshness Job spurious; investigate Job logs.
- `36 ≤ hours_stale < 72` → WARN tier, freshness Job should have
  exited 0 and no alert should fire. If alert did fire, the alert
  policy is misconfigured.
- `hours_stale ≥ 72` → ERROR tier, freshness Job correctly fired.
  Root cause is upstream: either `bronze-daily-load` is failing
  (see §2) or the crawler stopped writing (see §1). Resolve the
  upstream cause and the next hourly freshness Job naturally goes
  green.

## §5 — Relationships test WARN (severity=warn, not an alert)

The `relationships_fct_measurements_*_station_id` tests run with
`severity=warn`. They fire WARN — visible in dbt build logs and on
the dashboard via the dbt test panel — but **do not** trigger the
critical alert. Treated as something to investigate within 1-3
business days, not paged.

The mechanism: `dim_stations` is rebuilt from the *latest* CWA stations
snapshot every weekly run. A station decommissioned mid-year disappears
from the source ⇒ disappears from `dim_stations` ⇒ historical
`fct_measurements_*` rows referencing that station fail relationships.

Response options:

- **Accept the drop.** Document the decommissioned `station_id` in
  the dim_stations description. No code change.
- **Backfill dim.** Re-include the station via an explicit override in
  `int_stations__unioned`, with a `station_status = 'decommissioned'`
  flag. More work; only justified if downstream consumers need the
  station record to exist.

Either way, run the diagnostic first:

```bash
bq query --use_legacy_sql=false --location=asia-east1 \
  'SELECT station_id, COUNT(*) AS n
   FROM `side-project-staging.weather_marts.fct_measurements_10min`
   WHERE station_id NOT IN (
     SELECT station_id FROM `side-project-staging.weather_marts.dim_stations`
   )
   GROUP BY 1 ORDER BY n DESC LIMIT 20'
```

This is the same SQL the test runs, just adapted to show *which*
stations are missing.

## §6 — Anomaly test WARN

`anomaly_fct_measurements_daily_rowcount.sql` fires WARN when the
latest day's row count deviates > 3σ from the trailing 30-day mean.

Possible causes (in rough order of likelihood):
- Crawler partial outage → row count dropped
- Genuine weather event (typhoon density spike, fog season) → density rose
- New CWA station online / decommissioned → step change
- Parser bug dropping records

Investigation:

```bash
bq query --use_legacy_sql=false --location=asia-east1 \
  'SELECT DATE(measure_at) AS day, COUNT(*) AS n
   FROM `side-project-staging.weather_marts.fct_measurements_daily`
   WHERE measure_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 35 DAY)
   GROUP BY day ORDER BY day DESC'
```

Look for the discontinuity and decide if it's an event or a bug. If
event: no action. If bug: trace upstream layer by layer.

## §7 — Manual full pipeline replay (rare)

Only needed if data corruption is suspected across multiple layers.
The order matters:

1. **Bronze first** — re-run `bronze-daily-load` with a widened
   lookback (see §2).
2. **Marts second** — re-run `dbt-weekly-build` with
   `--full-refresh` on affected incremental models (see §3c).

Never re-run marts before re-running bronze if bronze is the
suspected cause; downstream rebuilds will inherit the same bad data.

For multi-week replay, prefer running `bronze-daily-load` once with a
month-long lookback over running it daily N times. MERGE is
idempotent but slot consumption isn't.

## Reference commands

Quick command index (copy-paste-able):

```bash
# List recent executions of any pipeline Job
gcloud run jobs executions list --region=asia-east1 --limit=10 \
  --format='table(name,status.startTime,status.completionTime,status.failedCount,status.succeededCount)'

# Tail logs for the most recent execution of a Job
gcloud logging read 'resource.type="cloud_run_job"
  AND resource.labels.job_name="<JOB_NAME>"' \
  --limit=100 --freshness=1d --format='value(timestamp,severity,textPayload)'

# Trigger a Job manually
gcloud run jobs execute <JOB_NAME> --region=asia-east1 --wait

# Trigger with a one-time env var override
gcloud run jobs execute <JOB_NAME> --region=asia-east1 \
  --update-env-vars="KEY1=v1,KEY2=v2" --wait

# Inspect the freshness gap directly
bq query --use_legacy_sql=false --location=asia-east1 \
  'SELECT MAX(ingest_at) AS latest,
          TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(ingest_at), HOUR) AS hours_stale
   FROM `side-project-staging.weather_raw.observations`'

# Inspect which station_ids the relationships test flags
bq query --use_legacy_sql=false --location=asia-east1 \
  'SELECT station_id, COUNT(*) AS n
   FROM `side-project-staging.weather_marts.fct_measurements_10min` f
   LEFT JOIN `side-project-staging.weather_marts.dim_stations` d
     USING (station_id)
   WHERE d.station_id IS NULL
   GROUP BY 1 ORDER BY n DESC LIMIT 20'
```

## Out of scope

- Cross-region failover. Single-region pipeline by design
  (`asia-east1`). If asia-east1 is offline, the pipeline is offline.
  Acceptable for this project's risk tolerance.
- Point-in-time recovery beyond GCS object versioning. We don't keep
  pre-MERGE bronze snapshots; bronze is the source of truth and is
  itself derivable from GCS.
- Incident severity / on-call rotation paperwork. Solo project; the
  on-call is whoever's reading this.
- Restoring from `terraform destroy`. The state bucket
  (`weather-pipeline-tfstate`) has versioning enabled; restoring
  pipeline infra means restoring TF state from a prior generation and
  re-applying. See `terraform/README.md` for the bootstrap recipe.

## References

- SLO targets and the pager-vs-investigate stance: [`docs/slo.md`](slo.md)
- Cost implications of widened lookback / full-refresh: [`docs/cost_performance.md`](cost_performance.md)
- Bronze MERGE logic: [`infra/bq/daily_load.sql`](../infra/bq/daily_load.sql)
- dbt source freshness config: [`weather_data_dbt/models/staging/_sources.yml`](../weather_data_dbt/models/staging/_sources.yml)
- Cloud Run Job specs: [`terraform/cloud_run_jobs.tf`](../terraform/cloud_run_jobs.tf)
