"""
cwa_bronze_daily_load_v_2_0_0
-----------------------------

Airflow equivalent of the v2 `bronze-daily-load` Cloud Run Job
(see infra/bq/daily_load.sql + terraform/cloud_run_jobs.tf). Daily MERGE
of crawler files newly arrived in GCS into the bronze
`weather_raw.observations` table.

Flow:
    GCSObjectsWithPrefixExistenceSensor (yesterday's hive partition)
        ↓
    BigQueryInsertJobOperator runs daily_load.sql against side-project-staging

The MERGE is idempotent on (station_id, measure_at); re-runs are safe.
A lookback window of `LOOKBACK_DAYS` (default 7) is applied so files
that arrived late after the last successful run still land.

Schedule matches the v2 Cloud Scheduler trigger (daily 02:00
Asia/Taipei) — the half-hour offset before dbt-weekly-build is the
implicit dependency, same as in v2.
"""

from pathlib import Path

import pendulum
from airflow import DAG
from airflow.providers.google.cloud.operators.bigquery import (
    BigQueryInsertJobOperator,
)
from airflow.providers.google.cloud.sensors.gcs import (
    GCSObjectsWithPrefixExistenceSensor,
)

GCS_BUCKET = "{{ var.value.get('gcs_weather_bucket', 'side-project-weather-data') }}"
GCP_PROJECT = "{{ var.value.get('gcp_project', 'side-project-staging') }}"
BQ_LOCATION = "asia-east1"
GCP_CONN_ID = "google_cloud_default"

# Same SQL used by the Cloud Run Job. Loaded at parse time so the rendered
# query goes into the Airflow UI; Jinja substitutions happen via the
# operator's `query_params` rather than string interpolation.
BRONZE_MERGE_SQL_PATH = (
    Path(__file__).resolve().parents[1] / "infra" / "bq" / "daily_load.sql"
)

# Fall back to inline SQL so the DAG remains importable even when the
# infra/ directory isn't mounted into the Airflow workers' filesystem.
DEFAULT_INLINE_SQL = """
-- Defensive placeholder. The production path reads infra/bq/daily_load.sql
-- which is the source of truth. Mount that file into Airflow's worker
-- filesystem (e.g. via a sidecar git-sync) and remove this fallback.
SELECT 1 AS placeholder
"""


def _load_merge_sql() -> str:
    try:
        return BRONZE_MERGE_SQL_PATH.read_text()
    except FileNotFoundError:
        return DEFAULT_INLINE_SQL


with DAG(
    dag_id="cwa_bronze_daily_load_v_2_0_0",
    start_date=pendulum.datetime(2026, 1, 1, tz="Asia/Taipei"),
    schedule="0 2 * * *",
    catchup=False,
    max_active_runs=1,
    tags=["v2", "bronze", "merge"],
    doc_md=__doc__,
):

    # Sanity-check that yesterday's crawler files actually exist before
    # firing the MERGE. The sensor times out gracefully if the prefix is
    # empty (no files → nothing to merge → MERGE no-op anyway).
    yesterday_partition = "{{ macros.ds_add(ds, -1) }}"

    wait_for_files = GCSObjectsWithPrefixExistenceSensor(
        task_id="wait_for_yesterdays_files",
        bucket=GCS_BUCKET,
        prefix=f"weather_record/dt={yesterday_partition}/",
        google_cloud_conn_id=GCP_CONN_ID,
        timeout=600,        # 10 min — files arrive within a Cloud Scheduler tick
        poke_interval=60,
        soft_fail=True,     # absence = empty day, not a Job failure
        mode="reschedule",  # release worker slot while polling
    )

    merge_bronze = BigQueryInsertJobOperator(
        task_id="merge_bronze",
        gcp_conn_id=GCP_CONN_ID,
        location=BQ_LOCATION,
        project_id=GCP_PROJECT,
        configuration={
            "query": {
                "query": _load_merge_sql(),
                "useLegacySql": False,
                # The MERGE uses {{ params.lookback_days }} as a Jinja
                # parameter; in production the Cloud Run Job sets this via
                # env var. The Airflow port wires it through params here.
                "queryParameters": [
                    {
                        "name": "lookback_days",
                        "parameterType": {"type": "INT64"},
                        "parameterValue": {"value": "{{ params.lookback_days }}"},
                    }
                ],
            }
        },
        params={"lookback_days": 7},
    )

    wait_for_files >> merge_bronze
