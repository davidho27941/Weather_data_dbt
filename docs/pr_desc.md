# BigQuery Bronze Layer + Bulk Load Infra

## Summary

Establish a BigQuery bronze layer (`weather_raw.observations`,
`weather_raw.weather_stations`, `weather_raw.rain_fall_stations`) populated by
shell scripts under `infra/bq/`. Covers both the one-time historical bulk
load (~70K JSON files / ~26 GiB raw → ~3–4 × 10⁷ rows after `UNNEST` and
dedup) and the daily ongoing ingest pattern. No dbt code changes — that's PR #3.

Also lands the design document
[`docs/redesign_proposal.md`](docs/redesign_proposal.md)
that motivates this and the next PR.

## Why this is its own PR

- **Operational, not code**: this PR's deliverables are scripts the operator
  runs once (bulk load) and a daily script. dbt code is untouched.
- **Independent rollback**: if the dbt rewrite (PR #3) hits a snag, the
  bronze tables remain valid and continue to accept daily updates.
- **Reviewable on its own**: ~8 small shell files plus design docs. PR #3
  rewrites every dbt model and benefits from being a separate diff.

## Approach (see [§14 of the design doc](docs/redesign_proposal.md))

The crawler's `json.dumps()` output is single-line compact JSON, which is
exactly what BigQuery's `NEWLINE_DELIMITED_JSON` expects. We can `bq load`
the GCS files directly without any conversion step. BigQuery's NESTED +
REPEATED schema preserves the original `records.Station[]` array, and a
follow-up `UNNEST` flattens it into one row per (station, observation
timestamp).

Two-step bulk load:

1. `bq load --autodetect --replace` into `*_staging` tables (raw nested).
2. `CREATE TABLE ... AS SELECT ... UNNEST(records.Station)` into the partitioned,
   clustered bronze tables. Sentinel values (`-99` / `-999`) are preserved
   verbatim — dbt staging cleans them in PR #3.

Daily load (`daily_load.sh`) follows the same shape but `MERGE`s into the
existing bronze table on `(station_id, measure_at)`, making re-runs idempotent
and absorbing late-arriving snapshots.

## Changes

### New: `infra/bq/`

| File | Purpose |
|---|---|
| [`README.md`](infra/bq/README.md) | Operator runbook — prereqs, env vars, run order, troubleshooting |
| [`00_create_dataset.sh`](infra/bq/00_create_dataset.sh) | `bq mk --dataset weather_raw @ asia-east1`. Idempotent. |
| [`01_bulk_load_staging.sh`](infra/bq/01_bulk_load_staging.sh) | `bq load --autodetect --replace` into 4 `*_staging` tables (observations + 3 station sources) |
| [`01b_bulk_load_legacy_staging.sh`](infra/bq/01b_bulk_load_legacy_staging.sh) | Optional: bulk-load legacy weather JSON from a different bucket (`gs://side-project-dev-s3/weather_record/`) into `observations_legacy_staging` |
| [`02_create_observations.sh`](infra/bq/02_create_observations.sh) | CTAS + `UNNEST(records.Station)`, auto-detects legacy staging table and `UNION ALL`s if present (dedup keyed on `station_id, measure_at`, new crawler wins on overlap) |
| [`03_create_stations.sh`](infra/bq/03_create_stations.sh) | Two CTAS jobs: `weather_stations` (manned UNION ALL unmanned, latest snapshot per station) and `rain_fall_stations` |
| [`04_drop_staging.sh`](infra/bq/04_drop_staging.sh) | Drop the four `*_staging` tables once verify.sh passes |
| [`verify.sh`](infra/bq/verify.sh) | 5 sanity-check queries (row counts, sentinel distribution, recent-day ingest gaps, station coverage) |
| [`daily_load.sql`](infra/bq/daily_load.sql) | Canonical daily-load SQL: `LOAD DATA OVERWRITE` → `MERGE` → `DROP TABLE`, parameterized by `@target_date`. Designed for BigQuery Scheduled Query deployment. |
| [`daily_load.sh`](infra/bq/daily_load.sh) | Thin wrapper around `daily_load.sql` for ad-hoc backfills (`YESTERDAY=2026-05-08 ./daily_load.sh`) and pre-deployment testing |

All shell scripts read four env vars with sensible defaults:
`GCP_PROJECT_ID=side-project-weather`, `BQ_DATASET=weather_raw`,
`BQ_LOCATION=asia-east1`, `GCS_BUCKET=side-project-weather-data`.
The optional `01b` step additionally reads `LEGACY_GCS_PATH`
(default `gs://side-project-dev-s3/weather_record/weather_report_10min-*.json`).

### New: `docs/`

- [`redesign_proposal.md`](docs/redesign_proposal.md) — full
  design doc covering §1 bug fixes (PR #1), §3–§14 BigQuery architecture
  including the bulk load runbook this PR implements (§14).
- [`pr_desc.md`](docs/pr_desc.md) — this file.

## Bronze schema

`weather_raw.observations`:
- One row per `(station_id, measure_at)`.
- Partition by `measure_date` (DAY).
- Cluster by `(station_id, station_type)`.
- Sentinel values **preserved** as-is; cleaning happens in dbt staging.
- Pre-computed `station_type` ('有人站' / '自動站' / '農業雨量站') so dbt does
  not need to recompute it.
- `ingest_source` column ('new' or 'legacy') for provenance; `ingest_at`
  is `NULL` for legacy rows (no `ingested_at` field in those files).

`weather_raw.weather_stations`:
- One row per CWA station, latest snapshot wins.
- `ingest_source` column ('manned' / 'unmanned') retained for provenance.
- Cluster by `station_id`.

`weather_raw.rain_fall_stations`:
- One row per agricultural rain-fall station, latest snapshot wins.
- Cluster by `station_id`.

## Test plan

Verification is by running scripts against the real GCS data. None of this
runs in CI — it's deployment-time validation by the operator.

- [ ] `00_create_dataset.sh` creates `weather_raw` (or no-ops if it exists).
- [ ] `01_bulk_load_staging.sh` finishes within 30 minutes; `bq ls weather_raw`
  shows four `*_staging` tables.
- [ ] `02_create_observations.sh` finishes within 3 minutes; observation row
  count is ~3–4 × 10⁷ scale.
- [ ] `03_create_stations.sh` finishes within 1 minute; `weather_stations` has
  rows for both `manned` and `unmanned` ingest sources.
- [ ] `verify.sh`: read each of the 5 output blocks. Sentinel counts > 0,
  recent-14-days row counts have no large gaps, station counts in the
  expected ranges.
- [ ] `04_drop_staging.sh` removes the four `*_staging` tables.
- [ ] Re-run `daily_load.sh YESTERDAY=2026-05-08` twice. The second run must
  produce the same bronze row count (idempotency check).

## What is NOT in this PR

Deliberately deferred to PR #3:

- **dbt code**: every staging / intermediate / mart model needs to be rewritten
  in BigQuery dialect (`UNNEST` instead of `lateral flatten`, `STARTS_WITH`
  instead of `STARTSWITH`, etc.).
- **GROUP BY rollup marts**: the design doc's §6 — replacing the per-row
  rolling-window pattern with `TIMESTAMP_TRUNC` aggregations.
- **Production deployment of `daily_load.sql` as a BQ Scheduled Query**: the
  SQL is written and tested via the shell wrapper, but actually creating the
  scheduled query (Console / Terraform) is left to PR #3 alongside the dbt
  Cloud Run Job setup. Until then `daily_load.sh` covers the gap.
- **Cloud Run Job for `dbt build`**: dbt is a Python tool, not pure SQL, so
  it cannot run as a Scheduled Query. The Cloud Run Job + Cloud Scheduler
  orchestration described in §13 of the design doc is PR #3's scope.
- **Terraform**: not introduced; bash scripts and the operator runbook are
  the only deployment surface for now.

## References

- Design doc: [`docs/redesign_proposal.md`](docs/redesign_proposal.md) §14
- Crawler that produces the source JSON: [`weather-crawler/`](weather-crawler/) (separate repo / sibling project)
- Branch: `feat/bigquery-bronze` → `main`
- Related: PR #1 (Snowflake bug fixes, branch `feat/refactor-sql`), PR #3 (dbt BigQuery migration, planned)
