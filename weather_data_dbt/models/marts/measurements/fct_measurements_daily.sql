{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['station_id', 'measure_at'],
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'day'},
        cluster_by=['station_id', 'station_type'],
        on_schema_change='append_new_columns',
    )
}}

{#
    fct_measurements_daily
    ----------------------
    Daily rollup. One row per (station_id, day). Day boundary is in
    Asia/Taipei (the bucketing timestamp lives in UTC but represents
    Taipei midnight).
#}

with measurements as (
    select * from {{ ref('int_measurements__cleaned') }}

    {% if is_incremental() %}
    where measure_at >= timestamp_sub(
        (select coalesce(max(measure_at), timestamp('1970-01-01')) from {{ this }}),
        interval {{ var('measurements_lookback_days') }} day
    )
    {% endif %}
),

bucketed as (
    select
        station_id,
        -- TIMESTAMP_TRUNC with a timezone returns a TIMESTAMP at the local
        -- midnight (here Taipei). No outer wrapping needed.
        timestamp_trunc(measure_at, day, 'Asia/Taipei') as measure_at,
        {{ measurement_aggregates('measurements') }}
    from measurements
    group by station_id, timestamp_trunc(measure_at, day, 'Asia/Taipei')
),

stations as (
    select * from {{ ref('dim_stations') }}
)

select
    b.station_id,
    b.measure_at,
    s.station_name,
    s.station_type,
    s.county_name,
    s.town_name,
    s.station_altitude,
    s.station_longitude,
    s.station_latitude,
    b.air_temperature_avg, b.air_temperature_max, b.air_temperature_min, b.air_temperature_obs_count,
    b.air_pressure_avg, b.air_pressure_max, b.air_pressure_min, b.air_pressure_obs_count,
    b.relative_humidity_avg, b.relative_humidity_max, b.relative_humidity_min, b.relative_humidity_obs_count,
    b.wind_speed_avg, b.wind_speed_max, b.peak_gust_speed_max,
    b.precipitation_sum, b.precipitation_max, b.precipitation_obs_count,
    b.sunshine_duration_sec, b.sunshine_obs_count,
    b.uv_index_max,
    b.observation_count
from bucketed b
left join stations s using (station_id)
