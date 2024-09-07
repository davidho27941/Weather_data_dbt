import json
import boto3
import snowflake.connector

from airflow import DAG
# from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from airflow.utils.task_group import TaskGroup

from airflow.decorators import task
from airflow.utils.trigger_rule import TriggerRule
from airflow.models import Variable

from airflow.providers.http.operators.http import HttpOperator
# from airflow.providers.mongo.hooks.mongo import MongoHook
# from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator

from datetime import datetime, timedelta

from botocore.exceptions import ClientError

from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, ExecutionConfig
from cosmos.profiles import SnowflakeUserPasswordProfileMapping
from pathlib import Path

from rich.progress import track

dbt_project_path = Path("/opt/airflow/dags/repo/dags/weather_data_dbt")


profile_config = ProfileConfig(
    profile_name="default",
    target_name="dev",
    profile_mapping=SnowflakeUserPasswordProfileMapping(
        conn_id="snowflake_dev", 
        profile_args={
            "database": "weather_data",
            "schema": "cwb_dev"
        },
))


with DAG(
    dag_id='cwa_transformation_incremental_v_1_0_0',
    start_date=datetime(2024,1,1),
    catchup=False,
    schedule="1 */2 * * *",
):

    transform_data = DbtTaskGroup(
        group_id="transform_data",
        project_config=ProjectConfig(dbt_project_path),
        operator_args={
            "install_deps": True,
            # "dbt_cmd_flags": ["--target-path"," /opt/airflow/new_target"]
        },
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=f"/opt/airflow/dbt_venv/bin/dbt",),
    )
    
    transform_data