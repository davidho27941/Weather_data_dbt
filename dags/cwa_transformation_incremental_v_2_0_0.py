"""
cwa_transformation_incremental_v_2_0_0
--------------------------------------

Airflow equivalent of the v2 `dbt-weekly-build` Cloud Run Job.
Mirrors v1's `cwa_transformation_incremental_v_1_0_0` shape (cosmos
DbtTaskGroup) but targets the GCP-native stack: BigQuery backend, dbt
profile `stg`, schema routed via the `generate_schema_name` macro.

Schedule matches the v2 Cloud Scheduler trigger (weekly Mon 02:30
Asia/Taipei). The 30-min offset after `cwa_bronze_daily_load_v_2_0_0`
is the implicit dependency on the daily MERGE having completed.

Execution: Cosmos ExecutionMode.WATCHER
---------------------------------------

Uses cosmos's "watcher" execution mode (battle-tested in cosmos 1.14):
a single dbt process per DAG run, with one Airflow deferrable sensor
per model that polls the producer's XCom stream for that model's
completion status. Per-model UI visibility is preserved but the
per-task `dbt` startup cost (~5-10s) is paid once instead of N times.
Reported gain on real workloads: up to ~80% DAG runtime reduction.

Caveats baked in:
  - Cosmos ≥ 1.14 required (drops Airflow < 2.9).
  - InvocationMode.DBT_RUNNER is required: dbt is invoked via its
    Python API rather than as a subprocess, so the watcher can stream
    structured events without parsing stdout.
  - WATCHER only handles `run` / `seed` / `snapshot`. Tests still run
    via standard cosmos test operators (one task per test) — at our
    ~80-test scale that's fine; tests are cheap on BQ.
  - `dbt build` is NOT a watcher-supported command. Cosmos's
    DbtTaskGroup decomposes the DAG into model + test pairs by default
    so we don't invoke `dbt build` directly; we get watcher acceleration
    on the model pass and standard execution on tests.
"""

import os
from pathlib import Path

import pendulum
from airflow import DAG

from cosmos import (
    DbtTaskGroup,
    ExecutionConfig,
    ProfileConfig,
    ProjectConfig,
    RenderConfig,
)
from cosmos.constants import ExecutionMode, InvocationMode, LoadMode
from cosmos.profiles import GoogleCloudOauthProfileMapping


# Production default assumes the repo is mounted at /opt/airflow/dags/repo
# (same convention as v1 DAG). Local-validation flows (see dev/) override
# both paths via env vars so the DAG resolves against the developer's venv.
DBT_PROJECT_PATH = Path(
    os.getenv(
        "DBT_PROJECT_PATH",
        "/opt/airflow/dags/repo/weather_data_dbt",
    )
)
DBT_EXECUTABLE_PATH = os.getenv(
    "DBT_EXECUTABLE_PATH",
    "/opt/airflow/dbt_venv/bin/dbt",
)


profile_config = ProfileConfig(
    profile_name="weather_data_dbt",
    target_name="stg",
    # Cosmos's GoogleCloudOauthProfileMapping reads ADC at runtime —
    # works locally with `gcloud auth application-default login` and in
    # GCP-hosted Airflow (Composer / Cloud Composer / self-managed on GKE
    # with Workload Identity).
    profile_mapping=GoogleCloudOauthProfileMapping(
        conn_id="google_cloud_default",
        profile_args={
            "project": "side-project-staging",
            "dataset": "weather",
            "location": "asia-east1",
            # Watcher fans models out concurrently up to this thread count
            # inside the single dbt process. Bumping threads gives a much
            # larger payoff under WATCHER than under per-model LOCAL mode.
            "threads": 8,
            "priority": "batch",
            "job_retries": 2,
        },
    ),
)


with DAG(
    dag_id="cwa_transformation_incremental_v_2_0_0",
    start_date=pendulum.datetime(2026, 1, 1, tz="Asia/Taipei"),
    schedule="30 2 * * 1",   # Mon 02:30 Asia/Taipei
    catchup=False,
    max_active_runs=1,
    tags=["v2", "dbt", "weekly", "incremental", "watcher"],
    doc_md=__doc__,
):

    transform_data = DbtTaskGroup(
        group_id="transform_data",
        project_config=ProjectConfig(DBT_PROJECT_PATH),
        profile_config=profile_config,
        # Parse the manifest at task-run time rather than DAG-parse time so
        # the scheduler isn't blocked on dbt's compilation pass. Trade-off:
        # task discovery in the UI requires a manifest rebuild.
        render_config=RenderConfig(load_method=LoadMode.DBT_LS),
        execution_config=ExecutionConfig(
            execution_mode=ExecutionMode.WATCHER,
            invocation_mode=InvocationMode.DBT_RUNNER,
            dbt_executable_path=DBT_EXECUTABLE_PATH,
        ),
        operator_args={
            "install_deps": True,
            # Same severity discipline as the Cloud Run Job: error-tier
            # test failures fail the DAG; warn-tier surface in logs and
            # in the dashboard via the log-based metric (see PR #7).
            "vars": '{"measurements_lookback_days": 7}',
        },
    )

    transform_data
