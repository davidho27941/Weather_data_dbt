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


@task(task_id='snowflake_preflight_check')
def snowflake_preflight_check(ti, **context):
    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_stage_name')
    
    try:
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
            # role='ACCOUNTADMIN'
        )
        cursor = snowflake_conn.cursor()
        
        cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {snowflake_schema_cwb};")
        cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {snowflake_schema_cwb}_intermediate;")
        cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {snowflake_schema_cwb}_transformed;")
        
        cursor.execute(f"CREATE TABLE {snowflake_schema_cwb}.raw IF NOT EXISTS (filename string, raw_data VARIANT);")
        cursor.execute(f"CREATE TABLE {snowflake_schema_cwb}.raw_stn IF NOT EXISTS (filename string, raw_data VARIANT);")
        cursor.execute(f"CREATE TABLE {snowflake_schema_cwb}.raw_stn_rain IF NOT EXISTS (filename string, raw_data VARIANT);")
        
        # cursor.execute(f"CREATE TABLE {snowflake_schema_cwb}_intermediate.extracted_json_v2 IF NOT EXISTS (filename string, raw_data VARIANT);")
        cursor.execute(
            f"""
            CREATE TABLE {snowflake_schema_cwb}_intermediate.extracted_json_v2 IF NOT EXISTS (
                STATIONID VARCHAR(16777216),
                STATIONNAME VARCHAR(16777216),
                OBSTIME TIMESTAMP_NTZ(9),
                WEATHER VARCHAR(16777216),
                AIRTEMPERATURE NUMBER(10,2),
                AIRPRESSURE NUMBER(10,2),
                RELATIVEHUMIDITY NUMBER(10,2),
                WINDSPEED NUMBER(10,2),
                WINDDIRECTION NUMBER(10,2),
                WINDDIRECTIONGUST NUMBER(10,2),
                PEAKGUSTSPEED NUMBER(10,2),
                PRECIPITATION NUMBER(10,2),
                SUNSHINEDURATION_10MIN NUMBER(10,2),
                VISIBILITY VARCHAR(16777216),
                UVINDEX NUMBER(10,2),
                GEOINFO VARIANT,
                STATIONFIELDSINFO VARIANT
            );
            """
        )
        # cursor.execute(f"CREATE TABLE {snowflake_schema_cwb}_transformerd.weather_records_v2 IF NOT EXISTS (filename string, raw_data VARIANT);")
        cursor.execute(
            f"""
            CREATE TABLE {snowflake_schema_cwb}_transformed.weather_records_v2 IF NOT EXISTS  (
                STATIONID VARCHAR(16777216),
                STATIONNAME VARCHAR(16777216),
                OBSTIME TIMESTAMP_NTZ(9),
                WEATHER VARCHAR(16777216),
                AIRTEMPERATURE NUMBER(10,2),
                AIRPRESSURE NUMBER(10,2),
                RELATIVEHUMIDITY NUMBER(10,2),
                WINDSPEED NUMBER(10,2),
                WINDDIRECTION NUMBER(10,2),
                WINDDIRECTIONGUST NUMBER(10,2),
                PEAKGUSTSPEED NUMBER(10,2),
                PRECIPITATION NUMBER(10,2),
                SUNSHINEDURATION_10MIN NUMBER(10,2),
                VISIBILITY VARCHAR(16777216),
                UVINDEX NUMBER(10,2)
            );
            """
        )
        
        cursor.execute(
            f"""
            CREATE TABLE {snowflake_schema_cwb}_transformed.GeoInfo_v2 IF NOT EXISTS  (
                StationID VARCHAR(16777216),
                STATIONNAME VARCHAR(16777216),
                CountyName VARCHAR(16777216),
                CountyCode VARCHAR(16777216),
                TownName VARCHAR(16777216),
                TownCode VARCHAR(16777216),
                StationAltitude NUMBER(10,2),
                StationLongitude NUMBER(10,5),
                StationLatitude NUMBER(10,5),
                STATIONSTATUS VARCHAR(16777216),
                Notes VARCHAR(16777216),
                Coordinates_TWD67 VARIANT,
                Coordinates_WGS84 VARIANT
            );
            """
        )
        
    except Exception as e:
        print(e)
        raise e
    
@task(task_id='list_s3_snowflake_diff_station_rain')
def list_s3_snowflake_diff_station_rain(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')

    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_stage_name')

    try:
        s3 = boto3.client(
            's3',
            region_name=s3_region_name,
            aws_access_key_id=s3_id,
            aws_secret_access_key=s3_key,
        )
        
        objects = s3.list_objects_v2(Bucket=s3_bucket_name, Prefix='rain_fall_station')
        s3_filelist = [obj['Key'].split('/')[-1] for obj in objects['Contents']]
        s3_filelist.remove('')
        print(f"{s3_filelist=}")
        
    except ClientError as e:
        print(e)
        raise e

    try:
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
            # role='ACCOUNTADMIN'
        )
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        cursor = snowflake_conn.cursor()
        cursor.execute(f"SELECT filename FROM {snowflake_schema_cwb}.raw_stn_rain")
        snowflake_record_list = [item[0] for item in cursor]
        print(f"{snowflake_record_list=}")
    except Exception as e:
        print(e)
        raise e
    
    diff = list(
        set(s3_filelist)
        .difference(set(snowflake_record_list))
    )

    print(f"Found number of different files: {len(diff)}")
    print(f"{diff=}")
    return diff

@task(task_id='list_s3_snowflake_diff_station')
def list_s3_snowflake_diff_station(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')

    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_stage_name')

    try:
        s3 = boto3.client(
            's3',
            region_name=s3_region_name,
            aws_access_key_id=s3_id,
            aws_secret_access_key=s3_key,
        )
        
        objects = s3.list_objects_v2(Bucket=s3_bucket_name, Prefix='weather_station_info')
        s3_filelist = [obj['Key'].split('/')[-1] for obj in objects['Contents']]
        s3_filelist.remove('')
        print(f"{s3_filelist=}")
        
    except ClientError as e:
        print(e)
        raise e

    try:
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
            # role='ACCOUNTADMIN'
        )
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        cursor = snowflake_conn.cursor()
        cursor.execute(f"SELECT filename FROM {snowflake_schema_cwb}.raw_stn")
        snowflake_record_list = [item[0] for item in cursor]
        print(f"{snowflake_record_list=}")
    except Exception as e:
        print(e)
        raise e
    
    diff = list(
        set(s3_filelist)
        .difference(set(snowflake_record_list))
    )

    print(f"Found number of different files: {len(diff)}")
    print(f"{diff=}")
    return diff


@task(task_id='list_s3_snowflake_diff')
def list_s3_snowflake_diff(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')

    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_stage_name')
    
    
    try:
        s3 = boto3.client(
            's3',
            region_name=s3_region_name,
            aws_access_key_id=s3_id,
            aws_secret_access_key=s3_key,
        )
        
        objects = s3.list_objects_v2(Bucket=s3_bucket_name, Prefix='weather_record')
        s3_filelist = [obj['Key'].split('/')[-1] for obj in objects['Contents']]
        s3_filelist.remove('')
        print(f"{s3_filelist=}")
        
    except ClientError as e:
        print(e)
        raise e

    try:
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
            # role='ACCOUNTADMIN'
        )
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        cursor = snowflake_conn.cursor()
        cursor.execute(f"SELECT filename FROM {snowflake_schema_cwb}.raw")
        snowflake_record_list = [item[0] for item in cursor]
        print(f"{snowflake_record_list=}")
    except Exception as e:
        print(e)
        raise e
    
    diff = list(
        set(s3_filelist)
        .difference(set(snowflake_record_list))
    )

    print(f"Found number of different files: {len(diff)}")
    print(f"{diff=}")
    return diff

@task(task_id='upload_snowflake')
def upload_snowflake(ti, **context):
    to_upload_files = ti.xcom_pull(task_ids='check_diff_s3_snowflake.list_s3_snowflake_diff')
    
    
    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_dev_stage_name')
    
    try:
        
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
        )
        
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        
        if len(to_upload_files) > 0:
            for file in track(to_upload_files, total=len(to_upload_files), description='Uploading to snowflake table.'):
                print(f"Uploading {file}.")
                snowflake_conn.cursor().execute(
                    f"""
                    COPY INTO {snowflake_schema_cwb}.raw
                    FROM (
                        SELECT 
                            '{file}', $1
                        FROM
                            @{snowflake_stage_name}/weather_record/{file}
                        )
                        FILE_FORMAT=(TYPE='JSON')
                    ;
                    """
                )
        
    except Exception as e:
        print(e)
        raise e

@task(task_id='upload_snowflake_stn')
def upload_snowflake_stn(ti, **context):
    to_upload_files = ti.xcom_pull(task_ids='check_diff_s3_snowflake.list_s3_snowflake_diff_station')
    
    
    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_dev_stage_name')
    
    try:
        
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
        )
        
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        if len(to_upload_files) > 0:
            for file in track(to_upload_files, total=len(to_upload_files), description='Uploading to snowflake table.'):
                print(f"Uploading {file}.")
                snowflake_conn.cursor().execute(
                    f"""
                    COPY INTO {snowflake_schema_cwb}.raw_stn
                    FROM (
                        SELECT 
                            '{file}', $1
                        FROM
                            @{snowflake_stage_name}/weather_station_info/{file}
                        )
                        FILE_FORMAT=(TYPE='JSON')
                    ;
                    """
                )
        
    except Exception as e:
        print(e)
        raise e

@task(task_id='upload_snowflake_stn_rain')
def upload_snowflake_stn_rain(ti, **context):
    to_upload_files = ti.xcom_pull(task_ids='check_diff_s3_snowflake.list_s3_snowflake_diff_station_rain')
    
    
    snowflake_user = Variable.get('snowflake_username')
    snowflake_password = Variable.get('snowflake_password')
    snowflake_account = Variable.get('snowflake_account')
    
    snowflake_database = Variable.get('snowflake_database')
    snowflake_schema_cwb = Variable.get('snowflake_schema_cwb_dev')
    snowflake_stage_name = Variable.get('snowflake_dev_stage_name')
    
    try:
        
        snowflake_conn = snowflake.connector.connect(
            user=snowflake_user,
            password=snowflake_password,
            account=snowflake_account,
            database=snowflake_database,
            schema=snowflake_schema_cwb,
            stage=snowflake_stage_name,
            warehouse = 'COMPUTE_WH',
            region='ap-northeast-1.aws',
        )
        
        snowflake_conn.cursor().execute(f"USE DATABASE {snowflake_database};")
        if len(to_upload_files) > 0:
            for file in track(to_upload_files, total=len(to_upload_files), description='Uploading to snowflake table.'):
                print(f"Uploading {file}.")
                snowflake_conn.cursor().execute(
                    f"""
                    COPY INTO {snowflake_schema_cwb}.raw_stn_rain
                    FROM (
                        SELECT 
                            '{file}', $1
                        FROM
                            @{snowflake_stage_name}/rain_fall_station/{file}
                        )
                        FILE_FORMAT=(TYPE='JSON')
                    ;
                    """
                )
        
    except Exception as e:
        print(e)
        raise e

with DAG(
    dag_id='cwa_transformation_v_0_3_0',
    start_date=datetime(2024,1,1),
    catchup=False,
    schedule="1 */2 * * *",
):
    snowflake_preflight_check_task = snowflake_preflight_check()
    
    with TaskGroup(group_id='check_diff_s3_snowflake') as check_diff_s3_snowflake:
    
        list_s3_snowflake_diff_task = list_s3_snowflake_diff()
        list_s3_snowflake_diff_station_task = list_s3_snowflake_diff_station()
        list_s3_snowflake_diff_station_rain_task = list_s3_snowflake_diff_station_rain()
    
    with TaskGroup(group_id='upload_snowflake_group') as upload_snowflake_group:
    
        upload_snowflake_task = upload_snowflake()
        upload_snowflake_stn_task = upload_snowflake_stn()
        upload_snowflake_stn_rain_task = upload_snowflake_stn_rain()

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
    
    snowflake_preflight_check_task >> check_diff_s3_snowflake >> upload_snowflake_group >> transform_data