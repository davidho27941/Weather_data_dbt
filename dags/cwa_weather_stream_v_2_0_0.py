"""
cwa_weather_stream_v_2_0_0
--------------------------

Airflow equivalent of the v2 crawler workload (in production this runs as
a Cloud Run *service* triggered by Cloud Scheduler every 10 minutes —
see infra/`weather-crawler/` and terraform/cloud_scheduler.tf). This DAG
implements the same behaviour with Airflow primitives so the v2 pipeline
shape can also be operated under an Airflow scheduler if needed.

Flow:
    HttpOperator → CWA observation API
        ↓ JSON
    @task.branch checks GCS bucket existence
        ↓ (create if missing) ↓
    @task uploads payload to GCS under weather_record/

Schedule matches the v2 Cloud Scheduler cadence (every 10 min).
"""

import json
from pathlib import Path

import pendulum
from airflow import DAG
from airflow.decorators import task
from airflow.models import Variable
from airflow.providers.google.cloud.hooks.gcs import GCSHook
from airflow.providers.google.cloud.operators.gcs import GCSCreateBucketOperator
from airflow.providers.http.operators.http import HttpOperator

GCS_BUCKET = "{{ var.value.get('gcs_weather_bucket', 'side-project-weather-data') }}"
GCS_LOCATION = "ASIA-EAST1"
GCS_CONN_ID = "google_cloud_default"


@task.branch(task_id="check_bucket_existence")
def check_bucket_existence(**context):
    """Branch on whether the target bucket exists; create it once if not."""
    bucket_name = Variable.get("gcs_weather_bucket", default_var="side-project-weather-data")
    hook = GCSHook(gcp_conn_id=GCS_CONN_ID)
    if hook.exists(bucket_name=bucket_name, object_name=""):
        return "upload_gcs"
    # GCSHook.exists on object_name="" is a soft check; fall back to listing.
    try:
        hook.list(bucket_name=bucket_name, max_results=1)
        return "upload_gcs"
    except Exception:
        return "create_bucket"


@task(task_id="upload_gcs")
def upload_gcs(get_weather_data_output, **context):
    """Write the CWA payload to gs://${bucket}/weather_record/weather_report_10min-${ts}.json."""
    bucket_name = Variable.get("gcs_weather_bucket", default_var="side-project-weather-data")

    payload = (
        get_weather_data_output
        if isinstance(get_weather_data_output, (dict, list))
        else json.loads(get_weather_data_output)
    )

    timestamp = pendulum.now("Asia/Taipei").format("YYYY-MM-DD_HH_mm")
    blob_name = f"weather_record/weather_report_10min-{timestamp}.json"

    hook = GCSHook(gcp_conn_id=GCS_CONN_ID)
    hook.upload(
        bucket_name=bucket_name,
        object_name=blob_name,
        data=json.dumps(payload),
        mime_type="application/json",
    )
    return blob_name


with DAG(
    dag_id="cwa_weather_stream_v_2_0_0",
    start_date=pendulum.datetime(2026, 1, 1, tz="Asia/Taipei"),
    schedule="*/10 * * * *",
    catchup=False,
    max_active_runs=1,
    tags=["v2", "ingest", "crawler"],
    doc_md=__doc__,
):

    token = "{{ var.value.cwa_auth_token }}"

    get_weather_data = HttpOperator(
        task_id="ping_cwa_api_task",
        http_conn_id="cwa_real_time_api",
        endpoint="/api/v1/rest/datastore/O-A0003-001",
        method="GET",
        data={
            "Authorization": token,
            "format": "JSON",
        },
        headers={"Content-Type": "application/json"},
        log_response=True,
        # response_filter lets us pass parsed JSON to downstream via XCom.
        response_filter=lambda r: r.json(),
    )

    create_bucket_task = GCSCreateBucketOperator(
        task_id="create_bucket",
        bucket_name=GCS_BUCKET,
        storage_class="STANDARD",
        location=GCS_LOCATION,
        gcp_conn_id=GCS_CONN_ID,
    )

    check_bucket_task = check_bucket_existence()
    upload_task = upload_gcs(get_weather_data.output)

    get_weather_data >> check_bucket_task
    check_bucket_task >> create_bucket_task >> upload_task
    check_bucket_task >> upload_task
