FROM apache/airflow:2.9.3 as base

# install dbt into a virtual environment
RUN python -m venv dbt_venv && source dbt_venv/bin/activate && \
    pip install --no-cache-dir dbt-snowflake dbt-postgres && deactivate

