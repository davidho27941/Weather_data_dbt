# weather_data_dbt

End-to-end data pipeline for Taiwan CWA (中央氣象署) weather observations.
Originally an Airflow + S3 + Snowflake stack; now fully migrated to a
GCP-native architecture (GCS + BigQuery + dbt + Cloud Run).

> Japanese README: [`multilingual_readme/readme_jp.md`](multilingual_readme/readme_jp.md)
> (AI-translated from this English version; the English README is authoritative).

## Architecture

```
                          ┌──────────────────┐
                          │ Cloud Scheduler  │  every 10 min cron
                          └────────┬─────────┘
                                   │ trigger
                                   ▼
       ┌──────────┐ HTTPS GET ┌──────────────┐
       │ CWA APIs │◀───────── │ weather-     │
       │          │── JSON ──▶│ crawler      │
       └──────────┘           │ (Cloud Run)  │
                              └──────┬───────┘
                                     │ write JSON files
                                     ▼
                              ┌─────────────┐
                              │ GCS bucket  │
                              │  weather_*  │
                              └──────┬──────┘
                                     │ bulk load (one-time)
                                     │ + daily MERGE (Cloud Run Job, daily 02:00)
                                     ▼
                          ┌────────────────────┐
                          │  BigQuery bronze   │
                          │  weather_raw.*     │
                          └─────────┬──────────┘
                                    │ dbt build  (Cloud Run Job, weekly Mon 02:30)
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

Two Cloud Monitoring alert policies feed the email notification channel:
one fires on any Cloud Run Job retry-exhausted failure
(`bronze-daily-load` / `dbt-weekly-build` / `dbt-hourly-freshness`); a
second fires specifically on dbt severity=error test failures via a
log-based metric, narrowing the on-call signal away from infra-class
failures. A `Weather pipeline health` Cloud Monitoring dashboard
surfaces Job execution by result, dbt test failures, BQ slot
utilisation, and crawler-bucket storage tiering. SLO targets and the
paging-vs-investigate stance live in
[`docs/slo.md`](docs/slo.md).

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
| [`infra/bq/`](infra/bq/) | Bronze layer: schema files, bulk load scripts, and `bronze-daily-load` Cloud Run Job (Dockerfile + deploy + scheduler scripts) |
| [`weather_data_dbt/`](weather_data_dbt/) | dbt project (BigQuery profile, dev / stg / prod / ci targets) |
| [`infra/dbt/`](infra/dbt/) | Dockerfile + scripts for the two Cloud Run Jobs (`dbt-weekly-build`, `dbt-hourly-freshness`) and their Cloud Scheduler triggers |
| [`infra/monitoring/`](infra/monitoring/) | Shell-script onboarding for the Cloud Monitoring email alert policy (now mirrored by Terraform — see below) |
| [`terraform/`](terraform/) | **Source of truth (PR #5 onward).** Single Terraform root managing SAs, IAM, AR repo, BQ datasets, crawler GCS bucket (with lifecycle), three Cloud Run Jobs, three Schedulers, Cloud Monitoring channel + alert policies + pipeline-health dashboard, log-based metric for dbt test failures. State in `gs://weather-pipeline-tfstate`. |
| [`.github/workflows/`](.github/workflows/) | GitHub Actions CI (PR validation) + CD (image push, Cloud Run Job rollout) + dbt docs publishing |
| [`docs/`](docs/) | `redesign_proposal.md` (design doc), [`decisions/`](docs/decisions/) (notes on non-obvious design choices), `slo.md` (SLOs + response stance), `pr_desc.md` (current PR description) |
| [`dags/`](dags/) | Airflow DAGs. `*_v_1_*` are the historical Snowflake-era v1; `*_v_2_0_0` are an Airflow-native port of the v2 architecture (crawler / bronze daily MERGE / weekly dbt build / hourly source freshness) — kept as a demonstration that the v2 design is portable to an orchestrator-based stack, not because they're wired into production. |
| [`dev/`](dev/) | uv-managed local Airflow sandbox for validating `*_v_2_0_0` DAG edits. The same bootstrap + check scripts run on every PR via [`.github/workflows/dag_check.yml`](.github/workflows/dag_check.yml) so local and CI exercise the same path. |
| Root `Dockerfile` | **Legacy** v1 Airflow image. Slated for removal in a follow-up cleanup PR. |

## Stack

| Layer | Tool / version |
|---|---|
| Crawler | FastAPI on Cloud Run; Python 3.12 |
| Object storage | GCS (`gs://${GCS_BUCKET}/`, hive-partitioned by `dt=YYYY-MM-DD`); tiered lifecycle: Standard → Nearline (30d) → Coldline (90d) → Archive (365d), no delete |
| Warehouse | BigQuery (`asia-east1`, `side-project-staging` / future `side-project-prod`) |
| Transformation | `dbt-core` 1.11.x · `dbt-bigquery` 1.11.x · `dbt_utils` 1.3.x |
| Orchestration | Three Cloud Run Jobs + Cloud Scheduler triggers: `bronze-daily-load` (`0 2 * * *`), `dbt-weekly-build` (`30 2 * * 1`), `dbt-hourly-freshness` (`0 * * * *`) |
| Alerting | Cloud Monitoring email alert policies: (1) any Cloud Run Job retry-exhausted failure, (2) dbt severity=error test failure via log-based metric `dbt_test_failure_count`. Pipeline-health dashboard in the same TF root. |
| Data quality | dbt tests on every model: `not_null` / `unique` / `accepted_values` / `accepted_range` (typhoon-tolerant bounds) / `unique_combination_of_columns` / `relationships` (severity=warn); plus singular tests for sentinel-translation invariant (severity=error) and row-count anomaly via z-score (severity=warn) |
| CI/CD | GitHub Actions (auth via service-account JSON keys; WIF migration documented) |
| IaC | Terraform `~> 6.0` google provider, single root in [`terraform/`](terraform/), state in GCS bucket `weather-pipeline-tfstate` |

## Environments

Three dbt targets backed by dataset-level isolation in BQ:

| Target | Purpose | Datasets |
|---|---|---|
| `dev` | Local developer runs (`gcloud auth application-default login`) | `weather_dev_{staging,intermediate,marts}` |
| `ci` | GitHub Actions PR validation | `weather_ci_{staging,intermediate,marts}` (rebuilt each run, 7-day bronze subsample) |
| `stg` | Weekly Cloud Run Job, Mon 02:30 Asia/Taipei (current source of truth) | `weather_{staging,intermediate,marts}` |
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
  [`dags/`](dags/) (`*_v_1_*` files) and the Airflow root `Dockerfile`.
  Diagrams under [`images/en/`](images/en/) reflect this stack.
- **v2 (current)**: GCP-native.
  - PR #2 — bronze layer in BigQuery (`weather_raw.*`) via bulk load + daily MERGE.
  - PR #3 — dbt rewrite for BigQuery, three Cloud Run Jobs (bronze daily, dbt weekly, dbt freshness hourly) wired with Cloud Scheduler triggers, GHA CI/CD.
  - PR #4 — Cloud Monitoring email alert on Cloud Run Job execution failures.
  - PR #5 — Terraform IaC for everything in PR #3 + PR #4 (single root in [`terraform/`](terraform/), state in `gs://weather-pipeline-tfstate`). Source of truth flips from shell scripts to `terraform apply`.
  - PR #6 — Crawler GCS bucket imported into Terraform with a tiered lifecycle (Standard → Nearline 30d → Coldline 90d → Archive 365d, no delete). `prevent_destroy = true` on the bucket to keep destroy a two-commit operation.
  - PR #7 — Data quality + observability hardening. Expanded dbt tests (relationships, accepted_range on all numeric measurement columns, sentinel-translation invariant, row-count anomaly via z-score), new log-based metric + alert policy for dbt severity=error failures, single `Weather pipeline health` Cloud Monitoring dashboard, [`docs/slo.md`](docs/slo.md) for explicit SLO targets.
  - PR #8 — Design decision notes under [`docs/decisions/`](docs/decisions/) for three non-obvious choices: STRING-typed bronze sentinels (001), dual-column raw + cleaned staging (002), and a proposal for enforcing dbt contracts on the marts layer (003, `Status: Proposed`). The contract enforcement lands in a separate follow-up PR so the design and the column-by-column implementation get reviewed independently.
  - PR #9 — Switched the `build_dbt_docs.yml` workflow to compile against `--target stg` so the published GitHub Pages catalog reflects prod row counts (was inheriting CI's 7-day subsample). New `gha-ci` `dataViewer` IAM bindings on `weather_{staging,intermediate,marts}` provisioned in Terraform.
  - PR #10 — Airflow-native port of the v2 architecture under [`dags/*_v_2_0_0`](dags/). Four DAGs mirror the v2 cadence (10-min crawler / daily MERGE / weekly dbt build / hourly source freshness) using `cosmos` for dbt and GCP providers for BigQuery + GCS. Demonstrates the v2 design is portable to an orchestrator-based stack; not wired into production (production stays on Cloud Run Jobs).

## Future work

- **Workload Identity Federation** for GitHub Actions, replacing the
  two SA-key secrets (eliminates key rotation toil).
- **Enforce dbt model contracts on the marts layer** — see
  [decision 003](docs/decisions/003-enforce-dbt-contracts-on-marts.md)
  for the design; implementation pending.
- **Webhook alert channel** (Discord / Slack / Pub-Sub) + **freshness wrapper** that posts structured per-source detail. Email channel can't carry granular freshness payloads usefully.
- **`sqlfluff` lint** in PR CI.
- **Cost / performance dashboards** — per-model BQ slot consumption, partition scan bytes, scheduled-query cost drill-down.
- **Renovate / Dependabot** for dbt-core / dbt-bigquery / SDK / base-image bumps.
- **BQ data-quality monitoring** (e.g. [`elementary-data`](https://github.com/elementary-data/elementary)
  layered on dbt artifacts) — would supersede the per-singular-test anomaly checks.
- **prod environment** — split `terraform/envs/{staging,prod}/`, stand up `side-project-prod`.
- **Terraform apply via GHA** with PR review gates (currently `apply` is a workstation operation).
- **Removing legacy Snowflake artifacts** (root v1 `Dockerfile`, old
  image references). `dags/` stays because it now also holds the v2
  Airflow port.
