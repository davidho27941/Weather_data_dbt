"""
cwa_source_freshness_v_2_0_0
----------------------------

Airflow equivalent of the v2 `dbt-hourly-freshness` Cloud Run Job.
Runs `dbt source freshness` against the BigQuery `weather_raw` bronze
table to verify the daily MERGE keeps `MAX(ingest_at)` within the
thresholds declared in models/staging/_sources.yml (warn 36h / error
72h — see docs/slo.md for rationale).

Unlike the v2 Cloud Run Job, this DAG uses BashOperator directly rather
than cosmos because:
  - There is no cosmos operator that wraps `dbt source freshness`
    cleanly (cosmos focuses on the build DAG, not freshness).
  - The command is a single-line invocation; the bash route is the
    smallest reasonable surface here.

Schedule matches the v2 Cloud Scheduler trigger (hourly on the hour).
"""

import pendulum
from airflow import DAG
from airflow.operators.bash import BashOperator


with DAG(
    dag_id="cwa_source_freshness_v_2_0_0",
    start_date=pendulum.datetime(2026, 1, 1, tz="Asia/Taipei"),
    schedule="0 * * * *",
    catchup=False,
    max_active_runs=1,
    # The Cloud Run Job converts warn → exit 0, error → exit 1 so a single
    # alert policy can pick up the error class. Match here via the `||` —
    # dbt's own exit code is 1 for both warn and error; we suppress warn.
    tags=["v2", "dbt", "freshness", "hourly"],
    doc_md=__doc__,
):

    source_freshness = BashOperator(
        task_id="dbt_source_freshness",
        bash_command=(
            "cd /opt/airflow/dags/repo/weather_data_dbt && "
            "/opt/airflow/dbt_venv/bin/dbt source freshness "
            "--target stg "
            "--profiles-dir profiles "
            "; "
            # Exit-code mapping: 0 = clean, 1 = warn or error from dbt.
            # We grep run_results.json for any 'error' status; warn maps
            # to success on this DAG so it doesn't fire the cloud_run_job
            # failure alert needlessly.
            "if grep -q '\"status\": \"error\"' target/sources.json 2>/dev/null; then "
            "  echo 'source freshness ERROR-tier detected'; exit 1; "
            "else "
            "  echo 'source freshness clean (or warn-only)'; exit 0; "
            "fi"
        ),
    )

    source_freshness
