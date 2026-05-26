{{
    config(
        materialized='table',
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'month'},
        cluster_by=['station_id', 'station_type'],
    )
}}

{#
    fct_measurements_weekly
    -----------------------
    Weekly rollup. One row per (station_id, week-starting-Monday). Week
    boundary follows ISO 8601 (Monday-start) which is the Taiwan
    convention.

    Materialized as a full table rather than incremental: the row count
    is small (~370 stations * 86 weeks since 2024-08 ≈ 32K), and the
    bucketing logic across week boundaries is finicky enough that a
    rebuild is simpler and the cost (~5 GB scan, ~$0.025/run) is trivial.
#}

with measurements as (
    select * from {{ ref('int_measurements__cleaned') }}
),

bucketed as (
    select
        station_id,
        -- Week starts Monday in Asia/Taipei. TIMESTAMP_TRUNC with timezone
        -- already returns the correct TIMESTAMP at the Taipei week-start.
        timestamp_trunc(measure_at, week(monday), 'Asia/Taipei') as measure_at,
        {{ measurement_aggregates('measurements') }}
    from measurements
    group by station_id, timestamp_trunc(measure_at, week(monday), 'Asia/Taipei')
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
    b.sunshine_duration_sum, b.sunshine_obs_count,
    b.uv_index_max,
    b.observation_count
from bucketed b
left join stations s using (station_id)
