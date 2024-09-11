# weather_data_dbt

## Introduction

This is a side project to build an end-to-end automated data pipeline. We use weather data provided by the Taiwan government as the data source. The automated pipeline is powered by the Apache Airflow, which is a well known automation tool. The data downloaded by the Airflow task will be uploaded to the AWS S3 Storage. The AWS S3 has been configured as an external table of the Snowflake Data Warehouse.

![Overview](./images/en/project_overview_en.jpg)

## Extract - Load Process

The automated data pipeline in this project is built on the Self-hosted Apache Airflow and uses AWS S3 as remote storage. The DAG is scheduled with different frequencies and gets the desired from the open data platform provided by Taiwan's government. The fetched data will be uploaded to AWS S3.

![Extract-Load](./images/en/extract_load_en.jpg)

## Transformation Process

In the data transformation pipeline, we use S3 Storage as an external table for Snowflake and utilize dbt (data build tool) to transform the data from the external table. The transformation process consists of three steps: staging, intermediate, and artifacts, each corresponding to different purposes.

![Transformation](./images/en/transformation_en.jpg)

For detail transformation and processing information, please refer to the auto-generated dbt document: [Web Page](https://davidho27941.github.io/weather_data_dbt/#!/overview)