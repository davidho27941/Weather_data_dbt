# dbt BigQuery Migration + Orchestration

## Summary

Rewrites the dbt project for BigQuery against the bronze layer landed in
PR #2. Introduces a three-environment topology (dev / stg / prod) with
dataset-level isolation, time-grain ML rollup marts, and the shell
infrastructure for Cloud Run Jobs that drive `dbt build` and
`dbt source freshness`. Also folds in the GitHub Actions CI/CD that
validates dbt PRs and rolls the Cloud Run Job image on every merge to
`main`.

The Snowflake-syntax models that survived through PR #1 are fully replaced.
There is no Snowflake compatibility shim — Snowflake was already disabled.

## Why this is its own PR

- **Bounded scope**: PR #2 produced the bronze tables; PR #3 consumes them
  via dbt and adds the orchestration to schedule the dbt build. The diff
  spans `weather_data_dbt/`, `infra/dbt/`, and a small `infra/bq/`
  follow-up (see "Bronze schema follow-up" below).
- **Independent operability**: bronze daily MERGE keeps running regardless
  of whether dbt has been deployed. If the dbt rewrite needs to roll back,
  the upstream pipeline is unaffected.
- **Reviewable on its own**: ~28 files; the architectural moves
  (env management, raw + cleaned dual columns, GROUP BY rollups,
  partition/cluster, station capability flags) each have a focused commit.

### Bronze schema follow-up

PR #2 was merged with the early autodetect-based bronze load; the
schema-driven refactor and the FLOAT-for-measurements decision were
finalized after PR #2 merged. Implementing raw + cleaned dual columns
(below) requires bronze measurement fields to be STRING, so this PR
includes:

- New [`infra/bq/schemas/observations.json`](infra/bq/schemas/observations.json)
  declaring measurements as STRING (preserves CWA sentinel codes verbatim).
- [`infra/bq/01_bulk_load_staging.sh`](infra/bq/01_bulk_load_staging.sh)
  updated to use `--schema=` for observation loads (autodetect retained
  for the simpler station-metadata loads).
- [`infra/bq/daily_load.sql`](infra/bq/daily_load.sql) MERGE source
  CASTs measurement columns to STRING so the daily incremental load
  matches the new bronze schema.

These bronze changes do **NOT** retroactively rebuild observed data — the
operator is expected to drop and re-run the bulk load (`infra/bq/01..04`)
once before turning on the dbt build.

## Environment topology

| Env | Purpose | GCP project | Auth |
|---|---|---|---|
| `dev` | Local developer runs | `side-project-staging` | `gcloud auth application-default login` (oauth) |
| `stg` | Automated weekly build (Mon 02:30 Asia/Taipei) | `side-project-staging` | Workload Identity on Cloud Run |
| `prod` | Future production | `side-project-prod` (TBD) | Workload Identity (must, no keyfiles) |

All three envs read source data from `weather_raw` (currently in
`side-project-staging`) by default; override per-env via `BRONZE_PROJECT`
env var when prod stands up its own bronze pipeline.

### Output dataset routing

Profile dataset is `weather` for every env. The custom
`generate_schema_name` macro in [`macros/generate_schema_name.sql`](weather_data_dbt/macros/generate_schema_name.sql)
appends a `_dev` infix only when `target.name == 'dev'`:

| Layer | dev | stg | prod |
|---|---|---|---|
| staging | `weather_dev_staging` | `weather_staging` | `weather_staging` |
| intermediate | `weather_dev_intermediate` | `weather_intermediate` | `weather_intermediate` |
| marts | `weather_dev_marts` | `weather_marts` | `weather_marts` |

Dev gets full physical isolation in the same project (different datasets,
separate IAM possible). Prod gets project-level isolation.

## Architecture

```
weather_raw                stg → int → marts
─────────────              ────────────────────
observations         ───▶  stg_observations         ───▶  int_measurements__cleaned   ───▶  fct_measurements_10min
                                                                                            fct_measurements_hourly
                                                                                            fct_measurements_daily
                                                                                            fct_measurements_weekly
                                                                                            fct_measurements_monthly

weather_stations     ───▶  stg_weather_stations     ─┐
                                                     ├─▶  int_stations__unioned     ───▶  dim_stations
rain_fall_stations   ───▶  stg_rain_fall_stations   ─┘                                       ▲
                                                                                              │ (joined into every fct_*)
```

Time-grain marts use `GROUP BY TIMESTAMP_TRUNC(...)` rather than per-row
window functions — a deliberate departure from the Snowflake design (which
emitted per-row rolling windows and filtered to bucket boundaries
post-hoc, conflating two separate concerns).

## Changes

### dbt project structure

| File | Purpose |
|---|---|
| [`dbt_project.yml`](weather_data_dbt/dbt_project.yml) | Rewritten: BQ profile, partition/cluster defaults, vars (`bronze_project`, `measurements_lookback_days`), four-layer dataset routing |
| [`packages.yml`](weather_data_dbt/packages.yml) | Adds `dbt_utils` (used for `accepted_range`, `unique_combination_of_columns`) |
| [`profiles/profiles.example.yml`](weather_data_dbt/profiles/profiles.example.yml) | Three-target template (dev / stg / prod) with env-var-driven project/dataset overrides |
| [`.gitignore`](weather_data_dbt/.gitignore) | Excludes `profiles.yml`, `target/`, `dbt_packages/`, `.user.yml` |

### Macros

| File | Status | Purpose |
|---|---|---|
| [`macros/generate_schema_name.sql`](weather_data_dbt/macros/generate_schema_name.sql) | **New** | Dev-infix schema routing |
| [`macros/classify_station_type.sql`](weather_data_dbt/macros/classify_station_type.sql) | **New** | 有人站 / 自動站 / 農業雨量站 from station_id prefix |
| [`macros/measurement_aggregates.sql`](weather_data_dbt/macros/measurement_aggregates.sql) | **New** | Shared SELECT fragment for time-grain rollup marts |
| `macros/cwa_sentinel_to_null.sql` | Kept | Already BQ-compatible from PR #1 |
| `macros/averaged_by_datetime.sql` | **Deleted** | Per-row rolling window, replaced by GROUP BY rollups |
| `macros/sum_over_datetime.sql` | **Deleted** | Same |
| `macros/find_max_in_interval.sql` | **Deleted** | Same |
| `macros/find_mode_in_interval.sql` | **Deleted** | Same |
| `macros/na_tag_to_null.sql` | **Deleted** | Subsumed by `cwa_sentinel_to_null` |

### Models

| Layer | New | Replaces |
|---|---|---|
| sources | `models/staging/_sources.yml` | (Snowflake `_*__sources.yml`) |
| staging | `stg_observations.sql`, `stg_weather_stations.sql`, `stg_rain_fall_stations.sql` + `_models.yml` | The subdirectory-per-source structure under Snowflake |
| intermediate | `int_measurements__cleaned.sql`, `int_stations__unioned.sql` + `_models.yml` | `int_measurements_aggregate_over_datetime`, `int_stations_join_all_informations` |
| marts (dimensions) | `marts/stations/dim_stations.sql` | `existing_stations.sql`, `revoked_stations.sql` |
| marts (facts) | `fct_measurements_10min.sql`, `fct_measurements_hourly.sql`, `fct_measurements_daily.sql`, `fct_measurements_weekly.sql`, `fct_measurements_monthly.sql` + `_models.yml` | `*_aggregated_measurements.sql` |

#### Notable design choices in the new models

- **Raw + cleaned dual columns for sentinel-bearing fields**. The CWA
  spec V1.05 documents 5 sentinel codes: `'X'` (instrument fail),
  `'T'` (trace precipitation), `'-99'` (missing), `'-98'` (no rain past
  6h, precipitation only), `'990'` (calm wind, undefined direction).
  Bronze observations stores measurement fields as STRING to preserve
  the raw CWA value (any of the sentinels can show up); dbt staging
  produces both `<field>_raw` (STRING) and `<field>` (FLOAT64,
  sentinel-translated). ML pipelines consume the cleaned column;
  governance / debugging queries the raw column. See
  [`weather_data_dbt/models/staging/stg_observations.sql`](weather_data_dbt/models/staging/stg_observations.sql)
  for the full sentinel-rule catalogue.
- **Bronze schema is explicit STRING for measurement fields** (per
  [`infra/bq/schemas/observations.json`](infra/bq/schemas/observations.json)).
  This is a deliberate departure from BigQuery autodetect, which would
  pick FLOAT and reject any 'X' / 'T' string at load time. With explicit
  STRING the load tolerates every sentinel value future CWA might encode,
  and the type translation happens once in dbt staging.
- **Station capability flags** in `stg_observations` (`has_pressure_sensor`,
  `has_sunshine_sensor`, `has_uv_sensor`). PR #2's verify.sh found ~90%
  sentinel values for `air_pressure`, `sunshine_duration`, `uv_index` —
  not because data is missing, but because automatic stations don't have
  those sensors. The flags let downstream ML pipelines tell "field not
  measured at this station" apart from "measurement missing this snapshot".
- **Incremental for 10-min / hourly / daily** with `merge` strategy and
  `unique_key=['station_id', 'measure_at']`; lookback window via the
  `measurements_lookback_days` var (default 10 days = 7-day cadence + 3-day buffer).
- **Full-table for weekly / monthly**: row counts are small (~32K and ~8K
  respectively), incremental adds complexity without meaningful cost
  savings.
- **Asia/Taipei calendar boundaries** for daily / weekly / monthly buckets.
  Weekly uses Monday-start (`WEEK(MONDAY)`) per Taiwan convention.
- **Pre-computed `station_type`** comes through from bronze (the bronze
  CTAS in `infra/bq/02_create_observations.sh` already classifies). dbt
  staging does not re-compute.

### Orchestration: `infra/dbt/`

| File | Purpose |
|---|---|
| [`Dockerfile`](infra/dbt/Dockerfile) | dbt-bigquery image with project + deps baked in; entrypoint honors `DBT_TARGET` |
| [`.dockerignore`](infra/dbt/.dockerignore) | Excludes secrets, build artifacts, sibling repos |
| [`entrypoint.sh`](infra/dbt/entrypoint.sh) | Forwards args to dbt with the configured target/profiles dir |
| [`build_and_push.sh`](infra/dbt/build_and_push.sh) | docker build + push to Artifact Registry |
| [`deploy_jobs.sh`](infra/dbt/deploy_jobs.sh) | gcloud run jobs deploy for `dbt-weekly-build` + `dbt-hourly-freshness` |
| [`README.md`](infra/dbt/README.md) | Operator runbook + Cloud Scheduler setup commands |

### CI/CD: `.github/workflows/`

| File | Trigger | Purpose |
|---|---|---|
| [`dbt_ci.yml`](.github/workflows/dbt_ci.yml) | PRs touching `weather_data_dbt/**` or `infra/dbt/**` | `dbt deps` + `dbt parse` + `dbt build --target ci --full-refresh --vars '{ci_sample_days: 7}'` against an isolated `weather_ci_*` dataset; runs all data tests as part of `build` |
| [`dbt_cd.yml`](.github/workflows/dbt_cd.yml) | Push to `main` touching `weather_data_dbt/**` or `infra/dbt/**` | Build + push the dbt-weather image to Artifact Registry under `${SHA}` and `latest` tags, then `gcloud run jobs update` to roll both Cloud Run Jobs onto the new image |
| [`build_dbt_docs.yml`](.github/workflows/build_dbt_docs.yml) | Push to `main` touching `weather_data_dbt/**` | Replaces the Snowflake-era docs workflow. `dbt docs generate --target ci` + publish to GitHub Pages |
| [`README.md`](.github/workflows/README.md) | — | One-time GCP setup (CI / CD service accounts, Artifact Registry repo, GitHub secrets/variables) and migration path to Workload Identity Federation |

A `ci` target is added to [`profiles.example.yml`](weather_data_dbt/profiles/profiles.example.yml)
and a `ci_sample_days` var to [`dbt_project.yml`](weather_data_dbt/dbt_project.yml).
When the var is non-zero, `stg_observations` filters bronze to the last
N days; this keeps each CI run under a minute on ~half a million rows
instead of full bronze (~25M). The fallback branch of
`generate_schema_name` routes the `ci` target to `weather_ci_*` datasets.

CI/CD authenticates to GCP via two service-account JSON keys
(`GCP_SA_KEY_CI`, `GCP_SA_KEY_CD`) stored as repo secrets. Workload
Identity Federation is the documented migration target — workflows
already request `id-token: write` so swapping in WIF is a two-line
change per workflow.

## Test plan

Bronze re-build (one-time, required because measurement fields change
type from FLOAT to STRING):

- [ ] `gcloud auth login && gcloud config set project side-project-staging`
- [ ] Drop existing bronze observations:
      `bq rm -f -t side-project-staging:weather_raw.observations`
      `bq rm -f -t side-project-staging:weather_raw.observations_staging`
      (and `observations_legacy_staging` if present)
- [ ] Re-run `infra/bq/01_bulk_load_staging.sh` — uses new explicit
      schema; preserves CWA sentinel strings ('X' / 'T' / '-99' / etc.).
- [ ] Re-run `infra/bq/02_create_observations.sh`.
- [ ] `infra/bq/verify.sh` confirms row counts unchanged from PR #2.

dbt local validation:

- [ ] `cd weather_data_dbt && cp profiles/profiles.example.yml profiles/profiles.yml`,
  edit if needed, then `dbt deps`.
- [ ] `gcloud auth application-default login`
- [ ] `dbt parse` — should succeed without deprecation warnings.
- [ ] `dbt build --target dev --full-refresh` — first run, full refresh
  of all models in `weather_dev_*` datasets. Should finish in <10 min.
- [ ] Inspect dev marts in BQ Console:
  - `dim_stations`: ~1500 rows (CWA + rain-fall, deduped)
  - `fct_measurements_10min`: ~25M rows, columns include `_raw` + cleaned pairs
  - `fct_measurements_hourly`: ~4M rows
  - `fct_measurements_daily`: ~225K rows
  - `fct_measurements_weekly`: ~32K rows
  - `fct_measurements_monthly`: ~8K rows
- [ ] Spot-check sentinel handling on `fct_measurements_10min`:
      `WHERE wind_direction_raw = '990' AND wind_direction IS NULL` should
      return rows; `WHERE precipitation_raw = '-98' AND precipitation = 0`
      should return rows.
- [ ] `dbt test --target dev` — every test passes.

Container build (manual):

- [ ] `infra/dbt/build_and_push.sh` builds and pushes the image.
- [ ] `gcloud run jobs execute dbt-weekly-build --region=asia-east1`
  reproduces a successful build against stg.

CI/CD (one-time setup per `.github/workflows/README.md`, then per-event):

- [ ] Create `gha-ci@…` and `gha-cd@…` service accounts and grant the
  scoped roles documented in the runbook.
- [ ] Add `GCP_SA_KEY_CI` and `GCP_SA_KEY_CD` to repo secrets.
- [ ] Enable GitHub Pages → Source = "GitHub Actions".
- [ ] Open a throwaway PR touching `weather_data_dbt/**` and confirm
  `dbt CI` runs `parse` + `build --target ci` + tests green.
- [ ] Merge to `main` and confirm `dbt CD` pushes a fresh image and
  rolls both Cloud Run Jobs (`gcloud run jobs describe dbt-weekly-build
  --region=asia-east1` shows the new digest).
- [ ] Confirm `dbt docs` workflow publishes to Pages.

## What is NOT in this PR

Deferred to PR #4 (or later):

- **Terraform** for SA / IAM / Artifact Registry / Cloud Run Jobs / Cloud
  Scheduler (§13.6 of the design doc). Shell scripts and the GHA runbook
  are the only deployment surface for now. Future Terraform will use a
  GCS backend; the current SA / IAM artifacts created by the runbook are
  importable.
- **Cloud Scheduler triggers** for the two Cloud Run Jobs. Documented in
  [`infra/dbt/README.md`](infra/dbt/README.md) as gcloud commands; not
  scripted because the schedule cadence may change once we have stg
  telemetry.
- **BigQuery Scheduled Query** setup for `infra/bq/daily_load.sql`. That
  needs Console-based config and is independent of dbt orchestration.
- **Failure alerting** (Slack / Discord webhooks for Cloud Run Job failures,
  freshness wrapper from §13.4.2, Cloud Monitoring alert policies from
  §13.9 P0).
- **Workload Identity Federation** for GitHub Actions. Workflows are wired
  for SA-key auth in this PR; WIF migration path documented in
  [`.github/workflows/README.md`](.github/workflows/README.md).
- **Bringing main's `infra/bq/`** scripts up to date with the schema-driven
  refactor (PR #2 was merged in an earlier state). Belongs in a small
  follow-up PR — does not block dbt work because the live bronze tables
  in BQ already have the correct schemas.

## References

- Bronze layer (PR #2): `infra/bq/`, `docs/redesign_proposal.md` §14
- Design doc: [`docs/redesign_proposal.md`](docs/redesign_proposal.md)
  §3-§7 (model layers), §13 (orchestration)
- Branch: `feat/dbt-bigquery-migration` → `main`
