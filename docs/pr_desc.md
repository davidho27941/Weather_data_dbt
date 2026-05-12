# Airflow port of the v2 pipeline (PR #10)

## Summary

Adds four Airflow DAGs under `dags/` named `cwa_*_v_2_0_0.py` that
mirror the v2 production pipeline (currently running on Cloud Run Jobs
+ Cloud Scheduler). The DAGs are **not wired into production** — the
Cloud Run Job stack stays canonical. The point is to demonstrate that
the v2 design is portable to an orchestrator-based deployment.

This also reframes the legacy `dags/` directory. Previously it was
"slated for removal" because v1 (Snowflake + S3 + Airflow) is dead.
Removing it would have been correct but uninformative. Keeping the v1
files alongside fresh v2 ports makes the migration story visible in
one folder: same problem, two stacks, both expressed.

## Mapping

| v2 production workload | v2 Airflow port |
|---|---|
| `weather-crawler` Cloud Run service (every 10 min, Cloud Scheduler) | [`cwa_weather_stream_v_2_0_0.py`](../dags/cwa_weather_stream_v_2_0_0.py) |
| `bronze-daily-load` Cloud Run Job (daily 02:00 Asia/Taipei) | [`cwa_bronze_daily_load_v_2_0_0.py`](../dags/cwa_bronze_daily_load_v_2_0_0.py) |
| `dbt-weekly-build` Cloud Run Job (Mon 02:30 Asia/Taipei) | [`cwa_transformation_incremental_v_2_0_0.py`](../dags/cwa_transformation_incremental_v_2_0_0.py) |
| `dbt-hourly-freshness` Cloud Run Job (hourly) | [`cwa_source_freshness_v_2_0_0.py`](../dags/cwa_source_freshness_v_2_0_0.py) |

## Operator choices

Three deliberate decisions worth flagging:

**1. `cosmos` for dbt — and specifically `ExecutionMode.WATCHER`.**
Matches the v1 `cwa_transformation_incremental_v_1_0_0` DAG that
already uses `DbtTaskGroup`. `cosmos` parses dbt's manifest at task
runtime and produces one Airflow task per dbt node, which gives the
Airflow UI real visibility into dbt graph progress — strictly more
useful than `BashOperator("dbt build")` lumping everything into one
opaque step.

On top of that, the dbt transformation DAG runs in **`ExecutionMode.WATCHER`**
(cosmos 1.14, battle-tested per the Astronomer release notes):
a single dbt process per DAG run, with one deferrable sensor per
model polling a producer's XCom stream. The per-task `dbt` startup
cost (~5-10s) is paid once instead of N times; reported runtime gain
on real workloads is up to ~80%. `InvocationMode.DBT_RUNNER` is set
in tandem so dbt is invoked via its Python API (necessary for the
watcher to receive structured events).

Caveats baked into the DAG comments:
  - Cosmos ≥ 1.14 required (drops Airflow < 2.9).
  - `WATCHER` only handles `run` / `seed` / `snapshot`. Tests still
    run via standard cosmos test operators — at ~80 tests on BQ this
    is fine; tests are cheap warehouse-side anyway.
  - `dbt build` itself is not a watcher-supported command, but
    cosmos's `DbtTaskGroup` decomposes the DAG into model + test
    pairs by default, so we don't invoke `dbt build` directly. Models
    get watcher acceleration; tests get the standard path.
  - Thread count bumped to 8 in the profile mapping — watcher fans
    models out concurrently inside the single dbt process up to this
    limit, so a higher `threads` pays off more under WATCHER than
    under per-model LOCAL.

**2. `BigQueryInsertJobOperator` for the bronze MERGE, not a custom
operator or BashOperator.**
The bronze MERGE is just a SQL statement; the v2 Cloud Run Job is the
runtime, not the logic. `BigQueryInsertJobOperator` is the canonical
Airflow primitive for submitting a BigQuery query job — it handles
auth via the existing `google_cloud_default` connection, returns the
BQ job ID for retry semantics, and Airflow's UI gets the linked job
URL for free.

**3. `BashOperator` for `dbt source freshness`, not `cosmos`.**
`cosmos` focuses on the *build* DAG; it doesn't currently wrap
`dbt source freshness` cleanly. Falling back to `BashOperator` for
this one task keeps the implementation simple. The DAG also encodes
the same warn→exit-0 / error→exit-1 mapping that the Cloud Run Job
uses so the same alert policy (when wired into Airflow's notifier)
would work without changes.

## What the DAGs assume

- Repository is mounted at `/opt/airflow/dags/repo/` (same convention
  v1 used).
- Airflow has the GCP provider package installed and a
  `google_cloud_default` connection configured against ADC or a SA
  JSON key.
- For `cosmos`, a Python venv at `/opt/airflow/dbt_venv/` has
  `dbt-bigquery` available, and the cosmos package itself is **≥ 1.14**
  (watcher mode prerequisite). Airflow itself must be **≥ 2.9** for the
  same reason.
- Two Airflow Variables: `cwa_auth_token` (for the CWA API) and
  optionally `gcs_weather_bucket` (defaults to
  `side-project-weather-data`).
- Two Airflow Connections: `cwa_real_time_api` (HTTP, base URL of the
  CWA API) and `google_cloud_default` (GCP).

The DAGs do not assume an Airflow deployment exists — they're code,
not infra. Running them requires standing up Airflow separately,
which is out of scope for this PR.

## Schedules

Match the v2 Cloud Scheduler triggers exactly. All declared in
Asia/Taipei via `pendulum.datetime(..., tz="Asia/Taipei")` on
`start_date`, so cron expressions are interpreted in local time
(matching how Cloud Scheduler reads `schedules` in
`terraform/variables.tf`).

| DAG | Cron | Asia/Taipei |
|---|---|---|
| `cwa_weather_stream_v_2_0_0` | `*/10 * * * *` | every 10 min |
| `cwa_bronze_daily_load_v_2_0_0` | `0 2 * * *` | daily 02:00 |
| `cwa_transformation_incremental_v_2_0_0` | `30 2 * * 1` | Mon 02:30 |
| `cwa_source_freshness_v_2_0_0` | `0 * * * *` | every hour on the hour |

## Changes

| File | Change |
|---|---|
| [`dags/cwa_weather_stream_v_2_0_0.py`](../dags/cwa_weather_stream_v_2_0_0.py) | New: HTTP → GCS crawler |
| [`dags/cwa_bronze_daily_load_v_2_0_0.py`](../dags/cwa_bronze_daily_load_v_2_0_0.py) | New: GCS sensor + bronze MERGE |
| [`dags/cwa_transformation_incremental_v_2_0_0.py`](../dags/cwa_transformation_incremental_v_2_0_0.py) | New: `cosmos.DbtTaskGroup` against `stg` target |
| [`dags/cwa_source_freshness_v_2_0_0.py`](../dags/cwa_source_freshness_v_2_0_0.py) | New: `dbt source freshness` via `BashOperator` |
| [`README.md`](../README.md) + [`multilingual_readme/readme_jp.md`](../multilingual_readme/readme_jp.md) | Reframed `dags/` row (no longer "slated for removal"); narrowed legacy-cleanup Future-work bullet to just the root v1 `Dockerfile`; Migration history bullets added for PR #9 and PR #10 |

## Test plan

These DAGs aren't deployed; verification is "does it parse + import?"

- [ ] `python -c "import dags.cwa_weather_stream_v_2_0_0"` (and same
      for the other three) — no `ImportError` from missing
      provider packages (`pip install apache-airflow-providers-google`
      and `astronomer-cosmos` if running locally).
- [ ] `airflow dags list` (in an Airflow environment) shows all four
      `*_v_2_0_0` DAGs.
- [ ] `airflow dags show cwa_weather_stream_v_2_0_0` renders the
      `get → check_bucket → (create) → upload` graph.
- [ ] No syntax errors (lints clean).

Not in scope: actually triggering the DAGs end-to-end. That requires
an Airflow deployment (Composer / self-hosted) which is its own
project.

## Out of scope

- **Deploying these DAGs.** Production stays on Cloud Run Jobs +
  Cloud Scheduler. If Airflow ever becomes the orchestrator, the
  decision to switch warrants its own design note + a separate PR.
- **A v2 port of `cwa_weather_station_stream`.** v2 loads stations
  via the one-shot `infra/bq/03_create_stations.sh` rather than on a
  schedule; an Airflow port would need to invent a cadence the v2
  architecture doesn't have.
- **A v2 `transformation_refresh` DAG.** v2 treats full-refresh as a
  manual incident-response operation (see
  [`docs/runbook.md`](runbook.md) §3c, currently local-only). Adding
  it as a DAG would imply we'd schedule full-refresh, which we
  explicitly don't.
- **Removing the root v1 `Dockerfile`.** Still tracked under Future
  work for a dedicated cleanup PR.

## References

- v1 reference DAGs: [`dags/cwa_weather_stream_v_1_2_0.py`](../dags/cwa_weather_stream_v_1_2_0.py),
  [`dags/cwa_transformation_incremental_v_1_0_0.py`](../dags/cwa_transformation_incremental_v_1_0_0.py)
- v2 production equivalents: [`terraform/cloud_run_jobs.tf`](../terraform/cloud_run_jobs.tf),
  [`terraform/cloud_scheduler.tf`](../terraform/cloud_scheduler.tf)
- `cosmos` (dbt + Airflow): <https://github.com/astronomer/astronomer-cosmos>
- Branch: `feat/airflow-dags-v2` → `main`
