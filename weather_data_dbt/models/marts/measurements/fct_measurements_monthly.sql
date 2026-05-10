{{
    config(
        materialized='table',
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'year'},
        cluster_by=['station_id', 'station_type'],
    )
}}

{#
    fct_measurements_monthly
    ------------------------
    Monthly rollup. One row per (station_id, month-start). Month boundary
    in Asia/Taipei.

    Like fct_measurements_weekly, materialized as a full table: row count
    is ~370 stations * 21 months ≈ 8K rows; full rebuild is trivial.
#}

with measurements as (
    select * from {{ ref('int_measurements__cleaned') }}
),

bucketed as (
    select
        station_id,
        -- Month boundary in Asia/Taipei.
        timestamp_trunc(measure_at, month, 'Asia/Taipei') as measure_at,
        {{ measurement_aggregates('measurements') }}
    from measurements
    group by station_id, timestamp_trunc(measure_at, month, 'Asia/Taipei')
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
