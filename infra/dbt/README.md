# dbt Cloud Run Job orchestration

Builds and deploys the two Cloud Run Jobs that run `dbt build` (weekly,
Mon 02:30 Asia/Taipei) and `dbt source freshness` (hourly) against the
`stg` target.

> Why Cloud Run Jobs and not BigQuery Scheduled Query: dbt is a Python
> tool — it compiles Jinja, runs tests, and emits a manifest. It cannot
> run inside a BQ Scheduled Query. The bronze daily load (`infra/bq/daily_load.sql`)
> is pure SQL and SHOULD run as a Scheduled Query; this directory only
> handles the dbt-specific orchestration.

## Architecture

```
Cloud Scheduler                    Cloud Run Job               BigQuery
─────────────────                  ─────────────               ────────
30 2 * * 1 Asia/Taipei  ───────▶  dbt-weekly-build      ───▶  weather_staging,
(Monday 02:30)                    (dbt build)                  weather_intermediate,
                                                               weather_marts
0  * * * * Asia/Taipei  ───────▶  dbt-hourly-freshness  ───▶  query history
                                  (dbt source freshness)
```

The bronze daily load runs separately as a BigQuery Scheduled Query at
02:00 Asia/Taipei every day; the weekly dbt build is offset 30 minutes
after Monday's bronze load so the freshest data is in place before dbt
reads it. The 7-day MERGE cadence is absorbed via
`measurements_lookback_days: 10` (7-day cadence + 3-day late-arrival
buffer).

## Files

```
infra/dbt/
├── README.md                 ← this file
├── Dockerfile                ← dbt-bigquery base + project + deps
├── .dockerignore             ← excludes target/, dbt_packages/, secrets, sibling repos
├── entrypoint.sh             ← dbt wrapper inside the container; honors DBT_TARGET
├── build_and_push.sh         ← docker build + push to Artifact Registry
├── deploy_jobs.sh            ← gcloud run jobs deploy (creates or updates)
└── deploy_schedulers.sh      ← gcloud scheduler jobs create/update for both triggers
```

## Prerequisites

- `gcloud` and `docker` CLI authenticated.
- Artifact Registry repo `dbt` exists in `${PROJECT}` (one-time setup):
  ```bash
  gcloud artifacts repositories create dbt \
    --repository-format=docker \
    --location=asia-east1 \
    --project=side-project-staging
  ```
- One-time docker auth helper for AR (writes credentials helper into
  `~/.docker/config.json`):
  ```bash
  gcloud auth configure-docker asia-east1-docker.pkg.dev
  ```
- Your individual gcloud account needs `roles/artifactregistry.writer` on
  the `dbt` repo if you intend to `build_and_push.sh` from a workstation
  (the GHA workflows use `gha-cd@…` instead):
  ```bash
  gcloud artifacts repositories add-iam-policy-binding dbt \
    --location=asia-east1 \
    --project=side-project-staging \
    --member="user:$(gcloud config get-value account)" \
    --role="roles/artifactregistry.writer"
  ```
- Service account `dbt-runner@${PROJECT}.iam.gserviceaccount.com` with:
  - `roles/bigquery.user` on the project
  - `roles/bigquery.dataEditor` on `weather_staging`, `weather_intermediate`,
    `weather_marts` (and `weather_dev_*` if you want stg jobs to be able to
    rebuild dev for some reason — usually not needed).
  - `roles/bigquery.dataViewer` on `weather_raw`
- Cloud Scheduler service account with `roles/run.invoker` on each Job
  (set up once when you create the Schedulers).

## Build + push

```bash
cd infra/dbt
./build_and_push.sh                # tags by current git SHA
./build_and_push.sh v1.0.0         # explicit tag
```

## Deploy / update Jobs

```bash
./deploy_jobs.sh                   # uses same default tag as build
./deploy_jobs.sh v1.0.0
```

Idempotent — re-runs update existing Jobs in place.

## Attach Cloud Scheduler triggers

After `scheduler-invoker@…` exists and has `roles/run.invoker` on both
Jobs (one-time setup in
[`.github/workflows/README.md` §2c](../../.github/workflows/README.md#2c-scheduler-invoker-sa-scheduler-invoker)):

```bash
./deploy_schedulers.sh
```

The script is idempotent (`describe` + branch to `create` / `update`).
It registers two triggers:

| Trigger | Schedule (Asia/Taipei) | Target Cloud Run Job |
|---|---|---|
| `dbt-weekly-build-trigger` | `30 2 * * 1` (Mon 02:30) | `dbt-weekly-build` |
| `dbt-hourly-freshness-trigger` | `0 * * * *` (top of every hour) | `dbt-hourly-freshness` |

## Test ad-hoc

```bash
# Trigger the weekly build manually
gcloud run jobs execute dbt-weekly-build --region=asia-east1

# Tail logs of the most recent execution
gcloud beta run jobs executions list --job=dbt-weekly-build --region=asia-east1 --limit=1
gcloud beta run jobs executions describe <execution-id> --region=asia-east1
```

## Authentication note

Inside Cloud Run Jobs, dbt-bigquery's `oauth` method picks up the runtime
service account's credentials via Workload Identity automatically — no
keyfile needed. The same `oauth` method works locally via
`gcloud auth application-default login`. Switch to a Workload Identity
binding (rather than oauth) for prod if you want stricter SA isolation.

## What is NOT here (deferred to PR #4)

- Terraform for SA / IAM / Artifact Registry / Cloud Scheduler. This PR
  ships shell scripts and runbook only.
- BigQuery Scheduled Query setup for `infra/bq/daily_load.sql`. That's a
  separate concern and only needs the Console / gcloud `bq` to set up.
- Slack / Discord alerting on Cloud Run Job failures.
