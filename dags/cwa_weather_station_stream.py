import json
import pytz
import boto3
import snowflake.connector

from airflow import DAG

from airflow.decorators import task
from airflow.utils.trigger_rule import TriggerRule
from airflow.models import Variable
from airflow.utils.task_group import TaskGroup

from airflow.providers.http.operators.http import HttpOperator

from datetime import datetime, timedelta

from botocore.exceptions import ClientError

from pathlib import Path


@task.branch(task_id='check_bucket_existence')
def check_bucket_existence(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')
    
    s3 = boto3.client(
        's3',
        region_name=s3_region_name,
        aws_access_key_id=s3_id,
        aws_secret_access_key=s3_key,
    )
    
    response = s3.list_buckets()
    
    print(response['Buckets'])

    if s3_bucket_name in response['Buckets']:
        return 'upload_s3'
    else: 
        return 'create_bucket'


@task(task_id='create_bucket')
def create_bucket(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')
    
    try:
        s3 = boto3.client(
            's3',
            region_name=s3_region_name,
            aws_access_key_id=s3_id,
            aws_secret_access_key=s3_key,
        )
        
        s3.create_bucket(Bucket=s3_bucket_name)
        
    except ClientError as e:
        print(e)
        raise e


    
@task(task_id='upload_s3', trigger_rule=TriggerRule.ONE_SUCCESS, retries=3, retry_delay=timedelta(minutes=1))
def upload_s3(ti, **context):
    s3_id = Variable.get('s3-side-project-id')
    s3_key = Variable.get('s3-side-project-key')
    s3_bucket_name = Variable.get('s3-dev-bucket-name')
    s3_region_name = Variable.get('s3-default-region')
    
    manned_data = ti.xcom_pull(task_ids='Get_Station_Info.get_manned_station')
    unmanned_data = ti.xcom_pull(task_ids='Get_Station_Info.get_unmanned_station')
    rain_fall_station_data = ti.xcom_pull(task_ids='Get_Station_Info.get_rain_fall_station')
    
    manned_data = json.loads(manned_data)
    unmanned_data = json.loads(unmanned_data)
    rain_fall_station_data = json.loads(rain_fall_station_data)
    
    
    s3 = boto3.client(
        's3',
        region_name=s3_region_name,
        aws_access_key_id=s3_id,
        aws_secret_access_key=s3_key,
    )
    
    try:
        # Follow the solution provided by: https://stackoverflow.com/questions/46844263/writing-json-to-file-in-s3-bucket
        # Alternative method: https://repost.aws/questions/QUemVDeKUTRm-KL7DjjHFtSA/uploading-a-file-to-s3-using-python-boto3-and-codepipeline
        timestamp = f"{datetime.now(pytz.timezone('Asia/Taipei')):%Y-%m-%d_%H_%M}"
        timestamp_to_pass = f"{datetime.now(pytz.timezone('Asia/Taipei')):%Y-%m-%d %H:%M}"
        
        manned_file_key = f'weather_station_info/weather_station_manned-{timestamp}.json'
        unmanned_file_key = f'weather_station_info/weather_station_unmanned-{timestamp}.json'
        rain_fall_station_file_key = f'rain_fall_station/weather_station_rain_fall-{timestamp}.json'
        s3.put_object(
            Body=json.dumps(manned_data),
            Bucket=s3_bucket_name,
            Key=manned_file_key
        )
        s3.put_object(
            Body=json.dumps(unmanned_data),
            Bucket=s3_bucket_name,
            Key=unmanned_file_key
        )
        s3.put_object(
            Body=json.dumps(rain_fall_station_data),
            Bucket=s3_bucket_name,
            Key=rain_fall_station_file_key
        )
        
    except ClientError as e:
        print(e)
        raise e

with DAG(
    dag_id='cwa_station_stream_v_1_0_0',
    start_date=datetime(2024,1,1),
    catchup=False,
    schedule="1 12 */7 * *",
):
    
    token = Variable.get('cwa_auth_token')
    with TaskGroup(group_id='Get_Station_Info') as get_data_group:
        get_manned_station = HttpOperator(
            task_id='get_manned_station',
            http_conn_id='cwa_real_time_api',
            endpoint="/api/v1/rest/datastore/C-B0074-001",
            method='GET',
            data={
                'Authorization': f'{token}',
                'format': "JSON",
            },
            headers={"Content-Type": "application/json"},
            log_response=True,
        )
        
        get_unmanned_station = HttpOperator(
            task_id='get_unmanned_station',
            http_conn_id='cwa_real_time_api',
            endpoint="/api/v1/rest/datastore/C-B0074-002",
            method='GET',
            data={
                'Authorization': f'{token}',
                'format': "JSON",
            },
            headers={"Content-Type": "application/json"},
            log_response=True,
        )
        
        get_rain_fall_station = HttpOperator(
            task_id='get_rain_fall_station',
            http_conn_id='rain_fall_stn_connection',
            endpoint="/api/v1/TaiwanRainfallStationInformationType",
            method='GET',
            headers={"Content-Type": "application/json"},
            log_response=True,
        )

    check_bucket_existence_task = check_bucket_existence()
    create_bucket_task = create_bucket()
    upload_s3_task = upload_s3()
    
    get_data_group >> check_bucket_existence_task
    check_bucket_existence_task >> create_bucket_task >> upload_s3_task
    check_bucket_existence_task >> upload_s3_task
    