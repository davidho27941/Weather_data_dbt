# Bronze Layer: BigQuery Bulk Load + Daily Ingest

One-time historical bulk load + ongoing daily ingest of weather observation
JSON from GCS into BigQuery native tables. The output (`weather_raw.observations`,
`weather_raw.weather_stations`, `weather_raw.rain_fall_stations`) is the bronze
layer dbt staging will read from in PR #3.

> Design rationale and architectural context: see
> [`docs/redesign_proposal.md`](../../docs/redesign_proposal.md)
> §14.

## Prerequisites

- `gcloud` and `bq` CLI installed and authenticated
  (`gcloud auth login`, `gcloud config set project side-project-weather`)
- IAM on the active account: at minimum `roles/bigquery.dataEditor` on the
  target dataset and `roles/storage.objectViewer` on the GCS bucket

## Environment variables (with defaults)

All scripts read these; export them once if you need to override:

| Variable | Default | Purpose |
|---|---|---|
| `GCP_PROJECT_ID` | `side-project-weather` | BQ project |
| `BQ_DATASET` | `weather_raw` | Bronze dataset |
| `BQ_LOCATION` | `asia-east1` | Dataset region |
| `GCS_BUCKET` | `side-project-weather-data` | Primary source bucket (new crawler) |
| `LEGACY_GCS_PATH` | `gs://side-project-dev-s3/weather_record/weather_report_10min-*.json` | Legacy weather observation glob (only used by `01b`) |

## One-time historical bulk load

Run once to backfill all data accumulated since 2024 (≈70K JSON files,
~26 GiB raw across both buckets):

```bash
cd infra/bq

./00_create_dataset.sh              # ~1s    — bq mk
./01_bulk_load_staging.sh           # 5–15 min — bq load 4 staging tables (new crawler, ~13 GiB)
./01b_bulk_load_legacy_staging.sh   # 5–15 min — OPTIONAL: legacy s3-bucket data (~12 GiB)
./02_create_observations.sh         # 1–3 min  — UNNEST + UNION ALL → ~3–4 × 10⁷ row bronze
./03_create_stations.sh             # < 1 min  — 2 station bronze tables
./verify.sh                         # < 1 min  — sanity checks (read these!)
./04_drop_staging.sh                # < 1s     — cleanup
```

Each script is idempotent (`--replace` on load, `CREATE OR REPLACE TABLE` on CTAS),
so re-running is safe. Total: **~15–35 minutes** wall time. BigQuery cost ≈ **$0.25**
for the bulk load + first month of bronze storage; daily ongoing load <$0.01/month.

### Legacy data (optional `01b` step)

If you have older weather observation JSON in a separate bucket
(e.g. `gs://side-project-dev-s3/weather_record/`), run `01b` after `01` to
load it into a `*_legacy_staging` table. Step `02` auto-detects the legacy
staging table and `UNION ALL`s it into the bronze observations table:

- Each legacy row carries `ingest_source = 'legacy'` and `ingest_at = NULL`
  (the `ingested_at` field was crawler-injected and is not present in the
  legacy data).
- Each new-crawler row carries `ingest_source = 'new'` and the parsed
  `ingest_at` timestamp.
- On `(station_id, measure_at)` overlap between the two sources, the new
  crawler row wins (`ORDER BY ingest_at DESC NULLS LAST`).

Skip `01b` if you have no legacy data — `02` falls back to new-staging only.

## Daily ongoing load

The daily load logic lives in [`daily_load.sql`](daily_load.sql) — a single
multi-statement BigQuery script that does `LOAD DATA OVERWRITE` →
`MERGE` → `DROP TABLE`. The SQL is the canonical source of truth; how it gets
invoked depends on environment.

### Production: Cloud Run Job `bronze-daily-load`

Deploy `daily_load.sql` as a Cloud Run Job triggered by Cloud Scheduler at
`0 2 * * *` Asia/Taipei. The Job's container image bakes in
`daily_load.sql` + `daily_load.sh`; the entrypoint runs the shell wrapper,
which invokes `bq query` with the SQL.

Why Cloud Run Job and not BigQuery Scheduled Query — schedule definition
lives in code (deploy via gcloud / GHA, not Console clicks); auth is bound
to a dedicated SA (not the user who created the schedule); failures and
logs land in Cloud Logging / Cloud Monitoring alongside the dbt jobs.

#### One-time setup

Service account `bronze-loader@${PROJECT}.iam.gserviceaccount.com` with:

- `roles/bigquery.user` on the project (run queries)
- `roles/bigquery.dataEditor` on the `weather_raw` dataset (write bronze)
- `roles/storage.objectViewer` on the GCS source bucket (read crawler JSON)

```bash
PROJECT=side-project-staging
SA=bronze-loader@${PROJECT}.iam.gserviceaccount.com
BUCKET=side-project-weather-data

gcloud iam service-accounts create bronze-loader \
  --project="${PROJECT}" \
  --display-name="bronze daily-load Cloud Run Job runtime"

gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" --role="roles/bigquery.user"

# Dataset-level grant via SQL DCL. `bq add-iam-policy-binding` would
# also work in theory but requires allowlisting on the project; GRANT
# does not.
bq query --use_legacy_sql=false --location=asia-east1 "
GRANT \`roles/bigquery.dataEditor\`
ON SCHEMA \`${PROJECT}.weather_raw\`
TO 'serviceAccount:${SA}'
"

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA}" --role="roles/storage.objectViewer"
```

#### Build, push, deploy

One-time docker auth helper (so `docker push` can talk to Artifact Registry):

```bash
gcloud auth configure-docker asia-east1-docker.pkg.dev
```

Your individual gcloud account also needs `roles/artifactregistry.writer`
on the `dbt` repo if you intend to push from a workstation (GHA uses
`gha-cd@…` separately):

```bash
gcloud artifacts repositories add-iam-policy-binding dbt \
  --location=asia-east1 \
  --project=side-project-staging \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/artifactregistry.writer"
```

Then build + deploy:

```bash
cd infra/bq
./build_and_push.sh                # builds + pushes bronze-loader:$SHA (linux/amd64)
./deploy_jobs.sh                   # creates / updates the Cloud Run Job
```

GitHub Actions ([`.github/workflows/bq_cd.yml`](../../.github/workflows/bq_cd.yml))
takes over after the one-time deploy: every push to `main` touching
`infra/bq/**` rebuilds the image and rolls the Cloud Run Job.

#### Cloud Scheduler trigger

After `scheduler-invoker@…` exists and has `roles/run.invoker` on
`bronze-daily-load` (one-time setup in
[`.github/workflows/README.md` §2c](../../.github/workflows/README.md#2c-scheduler-invoker-sa-scheduler-invoker)):

```bash
./deploy_scheduler.sh
```

The script is idempotent (`describe` + branch to `create` / `update`),
so re-running on schedule changes is safe. It registers the trigger
`bronze-daily-load-trigger` with cron `0 2 * * *` Asia/Taipei.

### Local / ad-hoc / backfill: [`daily_load.sh`](daily_load.sh) wrapper

```bash
# Default: load yesterday's data (Asia/Taipei)
./daily_load.sh

# Backfill a specific day
YESTERDAY=2026-05-08 ./daily_load.sh
```

The shell wrapper is a thin `bq query` invocation around `daily_load.sql`
that passes `--parameter='target_date:STRING:...'`. Useful before the
Scheduled Query is deployed, for one-off backfills, or for CI/cron-style
execution if you prefer that pattern over BQ schedules.

## Verification queries

After bulk load, [`verify.sh`](verify.sh) runs:

- Total row count vs unique stations vs date range
- Sentinel value distribution (-99, -999) per numeric column
- Per-day row count to spot ingest gaps
- Schema sanity: column names and types

Read the output before declaring success. Sentinel values should appear (CWA
uses them for missing readings); a complete absence likely means autodetect
mis-typed something.

## Troubleshooting

**Schema mismatch on daily load** (`Field X has changed type`)
- CWA added or changed a field. Drop `observations_daily_staging` and add
  `--schema_update_option=ALLOW_FIELD_ADDITION` to the `bq load` call, or
  update the bronze table schema manually before resuming.

**Duplicate rows after re-running daily load**
- Should not happen — `MERGE` keys on `(station_id, measure_at)`. If it does,
  check for clock skew in `ObsTime.DateTime` between snapshots, or for a
  station that legitimately reports two values at the same timestamp (rare
  but possible).

**`bq load` fails with "Invalid JSON"**
- Confirm the GCS files are single-line compact JSON (crawler default). If
  one was hand-edited and pretty-printed, it will fail because BQ expects
  one record per line. Either re-fetch via crawler or strip whitespace.

**Out-of-memory during `02_create_observations.sh`**
- Unlikely at this scale, but if it happens, partition the work by year:
  add `WHERE STARTS_WITH(ingested_at, '2024-')` to the CTAS, run, then
  `INSERT INTO` for 2025 / 2026 partitions.

## File layout

```
infra/bq/
├── README.md                          ← this file
├── 00_create_dataset.sh               ← bq mk --dataset
├── 01_bulk_load_staging.sh            ← bq load × 4 staging tables (new crawler)
├── 01b_bulk_load_legacy_staging.sh    ← OPTIONAL: bq load legacy s3-bucket observations
├── 02_create_observations.sh          ← CTAS + UNNEST + UNION ALL legacy if present
├── 03_create_stations.sh              ← 2 station tables (weather_stations + rain_fall_stations)
├── 04_drop_staging.sh                 ← drop *_staging tables (incl. legacy)
├── verify.sh                          ← sanity-check queries (incl. ingest_source split)
├── daily_load.sql                     ← canonical daily-load SQL (multi-statement bq script)
├── daily_load.sh                      ← thin wrapper: invokes daily_load.sql via bq CLI
├── Dockerfile                         ← bronze-loader Cloud Run Job image (cloud-sdk:slim)
├── build_and_push.sh                  ← docker build + push to Artifact Registry
├── deploy_jobs.sh                     ← gcloud run jobs deploy bronze-daily-load
└── deploy_scheduler.sh                ← gcloud scheduler jobs create/update for bronze trigger
```
