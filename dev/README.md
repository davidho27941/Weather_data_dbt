# dev/ — local validation tooling for the v2 Airflow DAGs

Three scripts to get a uv-managed local Airflow up so the
`*_v_2_0_0.py` DAGs can be eyeballed, parsed, and (optionally)
triggered without standing up Composer or a Docker stack.

| Script | What it does |
|---|---|
| [`airflow_bootstrap.sh`](airflow_bootstrap.sh) | `uv venv .venv-airflow` + install Airflow 2.10 + GCP/HTTP providers + Cosmos 1.14+ + dbt-bigquery 1.11.x. Idempotent — re-running upgrades in place. |
| [`airflow_check.sh`](airflow_check.sh) | Walks `dags/` via `DagBag`, surfaces import errors. No scheduler / webserver. Fast (~5 s). Run after every DAG edit. |
| [`airflow_run.sh`](airflow_run.sh) | `airflow standalone` — scheduler + webserver + SQLite metadata in one foreground process. Web UI at <http://localhost:8080>. |

## Quick start

```bash
# Once
./dev/airflow_bootstrap.sh

# After each DAG edit (~5 seconds, no Airflow processes)
./dev/airflow_check.sh

# Or boot the full UI
./dev/airflow_run.sh
```

## What's actually exercised

|  | `airflow_check.sh` | `airflow_run.sh` |
|---|---|---|
| DAG file imports cleanly (Python parses, all providers / cosmos importable) | ✅ | ✅ |
| Task graph renders in UI | — | ✅ |
| Cosmos parses dbt manifest (only when a task starts) | — | only on task trigger |
| Tasks actually execute (talk to BQ / GCS / CWA) | — | only with real auth + Airflow Variables + Connections |

For most "did I break the DAG?" feedback loops, `airflow_check.sh` is
enough. Boot the UI when you want to inspect the task graph visually
or want to confirm cosmos's `DbtTaskGroup` expansion under watcher mode.

A typical clean run prints something like:

```
==> Initialising Airflow metadata DB at .../airflow.db
...
Loaded 4 DAG(s):

  ✓ cwa_bronze_daily_load_v_2_0_0       schedule: 0 2 * * *    tasks: 2
  ✓ cwa_source_freshness_v_2_0_0        schedule: 0 * * * *    tasks: 1
  ✓ cwa_transformation_incremental_v_2_0_0  schedule: 30 2 * * 1  tasks: 24
  ✓ cwa_weather_stream_v_2_0_0          schedule: */10 * * * *  tasks: 4

All DAGs parsed cleanly.
```

The transformation DAG expanding to 24 tasks is the cosmos
`DbtTaskGroup` materialising one task per dbt node (11 models +
each model's tests) — exactly what watcher mode operates on.

## Why v1 DAGs don't appear

A [`.airflowignore`](../dags/.airflowignore) in `dags/` skips the four
`*_v_1_*` DAGs during local loading; they depend on `boto3` and
`snowflake-connector-python` that this dev venv doesn't install
(Snowflake era is over). They stay in the repo as historical record,
not as actively-loaded DAGs.

## What's NOT in scope

- **Running tasks end-to-end against live infra.** That requires real
  GCP auth (gcloud ADC or a SA key), a real CWA API token, and the
  Airflow Variables / Connections the DAGs reference. Wiring those up
  is a separate exercise. The DAGs are *designed* to be runnable, but
  this dev tooling is for validation, not staging.
- **Anything Docker-based.** `airflow standalone` runs on the host
  Python interpreter; no containers, no docker-compose.
- **Production parity.** This is `airflow standalone` with SQLite —
  good enough to validate DAGs but not a fair stand-in for Composer or
  any HA Airflow deployment.

## How DAG paths get rerouted

The v2 transformation DAG (and the freshness DAG) default to production
paths like `/opt/airflow/dbt_venv/bin/dbt` and
`/opt/airflow/dags/repo/weather_data_dbt`. The `airflow_run.sh` /
`airflow_check.sh` scripts override those via environment variables:

```bash
export DBT_PROJECT_PATH="${REPO_ROOT}/weather_data_dbt"
export DBT_PROJECT_DIR_LOCAL="${REPO_ROOT}/weather_data_dbt"
export DBT_EXECUTABLE_PATH="${REPO_ROOT}/.venv-airflow/bin/dbt"
```

The DAGs read those via `os.getenv(..., <prod_default>)` so the same
file works locally and in production without conditionals.

## Cleanup

```bash
rm -rf .venv-airflow .airflow-home
```

Both directories are `.gitignore`'d.

## Same scripts run in CI

[`/.github/workflows/dag_check.yml`](../.github/workflows/dag_check.yml)
runs `./dev/airflow_bootstrap.sh` (with `.venv-airflow/` cached on the
runner) and then `./dev/airflow_check.sh` on every PR touching
`dags/`, `weather_data_dbt/`, or `dev/`. So the local feedback loop
and the merge gate exercise the exact same code path — a DAG that
parses locally also passes CI, and a CI failure can be reproduced
locally without "works on my machine" debugging.

## Pinned versions

Cosmos 1.14+ for `ExecutionMode.WATCHER` is the load-bearing pin; that
forces Airflow ≥ 2.9, so the bootstrap uses 2.10.3 (current stable in
the 2.10.x line). dbt-bigquery matches the production project at
`>=1.11,<1.12`. Override via env vars passed to bootstrap if you need
a different version:

```bash
AIRFLOW_VERSION=2.10.4 ./dev/airflow_bootstrap.sh
```
