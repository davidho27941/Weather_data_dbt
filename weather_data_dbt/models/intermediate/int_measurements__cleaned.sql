{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['station_id', 'measure_at'],
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'day'},
        cluster_by=['station_id'],
        on_schema_change='append_new_columns',
    )
}}

{#
    int_measurements__cleaned
    -------------------------

    Per-row deduplicated, sentinel-cleaned measurement table at original
    10-minute granularity. The bronze CTAS already deduplicated on
    (station_id, measure_at), but we re-apply here as a safety net in case
    daily MERGE introduces duplicates from a re-run of the same window.

    Incremental strategy: re-scan the last `measurements_lookback_days`
    days of the source so late-arriving snapshots get re-merged. Default
    is 5 days (see dbt_project.yml `vars`).
#}

with measurements as (
    select * from {{ ref('stg_observations') }}

    {% if is_incremental() %}
    where measure_at >= timestamp_sub(
        (select coalesce(max(measure_at), timestamp('1970-01-01')) from {{ this }}),
        interval {{ var('measurements_lookback_days') }} day
    )
    {% endif %}
),

deduped as (
    select * except(rn)
    from (
        select
            *,
            row_number() over (
                partition by station_id, measure_at
                order by ingest_at desc nulls last
            ) as rn
        from measurements
    )
    where rn = 1
)

select * from deduped
