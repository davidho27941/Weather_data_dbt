# weather_data_dbt

End-to-end data pipeline for Taiwan CWA (中央氣象署) weather observations.
Originally an Airflow + S3 + Snowflake stack; now fully migrated to a
GCP-native architecture (GCS + BigQuery + dbt + Cloud Run).

> Japanese README: [`multilingual_readme/readme_jp.md`](multilingual_readme/readme_jp.md)
> (AI-translated from this English version; the English README is authoritative).

## Architecture

```
                ┌──────────────┐  every 10 min  ┌─────────────┐
   CWA APIs ───▶│ weather-     │ ──────────────▶│  GCS bucket │
                │ crawler      │   JSON files    │  weather_*  │
                │ (Cloud Run)  │                 └──────┬──────┘
                └──────────────┘                        │
                                                        │ bulk load (one-time)
                                                        │ + daily MERGE (Scheduled Query)
                                                        ▼
                                              ┌────────────────────┐
                                              │  BigQuery bronze   │
                                              │  weather_raw.*     │
                                              └─────────┬──────────┘
                                                        │
                                                        │ dbt build  (Cloud Run Job, daily 02:30)
                                                        │ dbt source freshness  (Cloud Run Job, hourly)
                                                        ▼
                          ┌────────────────────────────────────────────────┐
                          │  BigQuery silver / gold                        │
                          │  weather_staging   →   weather_intermediate    │
                          │                          ↓                     │
                          │                    weather_marts               │
                          │   fct_measurements_{10min,hourly,daily,        │
                          │                     weekly,monthly}            │
                          │   dim_stations                                 │
                          └────────────────────────────────────────────────┘
```

Three time-grain rollups feed downstream ML training; `dim_stations`
joins into every fact table. Sentinel-bearing measurement fields
(`'X'`, `'T'`, `'-99'`, `'-98'`, `'990'`) are stored as STRING in
bronze and exposed in dbt staging as both raw + cleaned columns so
governance and ML pipelines pick the column they need.

For the full design rationale see [`docs/redesign_proposal.md`](docs/redesign_proposal.md);
for the most recent change set see [`docs/pr_desc.md`](docs/pr_desc.md).

## Repository layout

| Path | Purpose |
|---|---|
| [`weather-crawler/`](weather-crawler/) | FastAPI service (Cloud Run) that fetches CWA APIs and writes JSON to GCS |
| [`infra/bq/`](infra/bq/) | Bronze layer: schema files + bulk load and daily MERGE shell scripts |
| [`weather_data_dbt/`](weather_data_dbt/) | dbt project (BigQuery profile, dev / stg / prod / ci targets) |
| [`infra/dbt/`](infra/dbt/) | Dockerfile + scripts for the two Cloud Run Jobs (`dbt-daily-build`, `dbt-hourly-freshness`) |
| [`.github/workflows/`](.github/workflows/) | GitHub Actions CI (PR validation) + CD (image push, Cloud Run Job rollout) + dbt docs publishing |
| [`docs/`](docs/) | `redesign_proposal.md` (design doc) and `pr_desc.md` (current PR description) |
| `dags/`, root `Dockerfile` | **Legacy** v1 Airflow + Snowflake; no longer wired into anything. Slated for removal in a follow-up cleanup PR. |

## Stack

| Layer | Tool / version |
|---|---|
| Crawler | FastAPI on Cloud Run; Python 3.12 |
| Object storage | GCS (`gs://${GCS_BUCKET}/`, hive-partitioned by `dt=YYYY-MM-DD`) |
| Warehouse | BigQuery (`asia-east1`, `side-project-staging` / future `side-project-prod`) |
| Transformation | `dbt-core` 1.11.x · `dbt-bigquery` 1.11.x · `dbt_utils` 1.3.x |
| Orchestration | Cloud Run Jobs + Cloud Scheduler (BQ Scheduled Query for the bronze MERGE) |
| CI/CD | GitHub Actions (auth via service-account JSON keys; WIF migration documented) |

## Environments

Three dbt targets backed by dataset-level isolation in BQ:

| Target | Purpose | Datasets |
|---|---|---|
| `dev` | Local developer runs (`gcloud auth application-default login`) | `weather_dev_{staging,intermediate,marts}` |
| `ci` | GitHub Actions PR validation | `weather_ci_{staging,intermediate,marts}` (rebuilt each run, 7-day bronze subsample) |
| `stg` | Daily Cloud Run Job (current source of truth) | `weather_{staging,intermediate,marts}` |
| `prod` | Reserved for `side-project-prod` once it stands up | (same dataset names, separate project) |

The custom [`generate_schema_name`](weather_data_dbt/macros/generate_schema_name.sql)
macro handles routing.

## Quick start (local dev)

```bash
# 1. Auth
gcloud auth application-default login
gcloud config set project side-project-staging

# 2. dbt environment (uv venv recommended)
uv venv && source .venv/bin/activate
uv pip install 'dbt-core>=1.11,<1.12' 'dbt-bigquery>=1.11,<1.12'

# 3. Profile + deps
cd weather_data_dbt
cp profiles/profiles.example.yml profiles/profiles.yml
dbt deps --profiles-dir profiles

# 4. Build
dbt build --target dev --profiles-dir profiles
```

dbt docs are auto-published to GitHub Pages on every push to `main`:
[Web Page](https://davidho27941.github.io/Weather_data_dbt/#!/overview).

## Migration history

- **v1 (deprecated)**: Airflow 2.9 + AWS S3 + Snowflake. Source under
  [`dags/`](dags/) and the Airflow root `Dockerfile`. Diagrams under
  [`images/en/`](images/en/) reflect this stack.
- **v2 (current)**: GCP-native. Bronze added in PR #2; dbt rewrite for
  BigQuery + Cloud Run Jobs + GHA CI/CD in PR #3.

## Future work

Tracked under "What is NOT in this PR" in [`docs/pr_desc.md`](docs/pr_desc.md):

- Terraform for SA / IAM / Artifact Registry / Cloud Run Jobs / Scheduler
- Cloud Scheduler triggers (currently as gcloud commands in [`infra/dbt/README.md`](infra/dbt/README.md))
- BQ Scheduled Query setup for `infra/bq/daily_load.sql`
- Failure alerting (freshness wrapper + Cloud Monitoring + Discord/Slack webhooks)
- Workload Identity Federation for GitHub Actions
- Removing legacy Airflow / Snowflake artifacts
