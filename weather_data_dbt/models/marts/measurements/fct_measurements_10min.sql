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
    fct_measurements_10min
    ----------------------

    Original 10-minute granularity weather observations + station context,
    ready for ML training. One row per (station_id, measure_at). Sentinel
    values are NULL (cleaned by stg_observations).

    Includes the station_capabilities flags so a model can choose to drop
    rows with `has_pressure_sensor = false` if it depends on pressure.

    Per ADR-004, CWA O-A0003-001's Precipitation / SunshineDuration are
    daily-cumulative since Asia/Taipei midnight (NOT 10-min windows).
    Both views are exposed:

        precipitation_daily_cumulative          running daily total (mm)
        precipitation_10min_window              true past-10-min amount, LAG-diff derived
        sunshine_duration_daily_cumulative      running daily total (h)
        sunshine_duration_10min_window          true past-10-min amount, LAG-diff derived

    ML consumers wanting per-bucket precipitation should use the
    `*_10min_window` columns. Governance / debug queries that need the
    daily running total use the `*_daily_cumulative` columns. The rollup
    facts (hourly/daily/weekly/monthly) SUM the window column — the
    cumulative one would be nonsense to sum.

    Incremental: re-scans last `measurements_lookback_days` to absorb
    late-arriving snapshots.
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

stations as (
    select * from {{ ref('dim_stations') }}
)

select
    -- ids and station context
    m.station_id,
    m.station_name,
    m.station_type,

    -- station capability flags
    m.has_pressure_sensor,
    m.has_sunshine_sensor,
    m.has_uv_sensor,

    -- geography (from dim_stations, falls back to bronze geo if not in dim)
    coalesce(s.county_name, m.county_name) as county_name,
    coalesce(s.town_name, m.town_name)     as town_name,
    coalesce(s.station_altitude, m.station_altitude) as station_altitude,
    s.station_longitude,
    s.station_latitude,

    -- measurements: raw (STRING, original CWA value) + cleaned (FLOAT64, sentinels translated).
    -- For precipitation / sunshine_duration the cleaned value is the DAILY
    -- CUMULATIVE total (per ADR-004); the *_10min_window column is the
    -- LAG-diff-derived past-10-min amount.
    m.air_temperature_raw,
    m.air_temperature,
    m.air_pressure_raw,
    m.air_pressure,
    m.relative_humidity_raw,
    m.relative_humidity,
    m.wind_speed_raw,
    m.wind_speed,
    m.wind_direction_raw,
    m.wind_direction,
    m.wind_direction_gust_raw,
    m.wind_direction_gust,
    m.peak_gust_speed_raw,
    m.peak_gust_speed,
    m.precipitation_daily_cumulative_raw,
    m.precipitation_daily_cumulative,
    m.precipitation_10min_window,
    m.sunshine_duration_daily_cumulative_raw,
    m.sunshine_duration_daily_cumulative,
    m.sunshine_duration_10min_window,
    m.uv_index_raw,
    m.uv_index,
    m.weather_status_raw,
    m.weather_status,
    m.visibility_raw,
    m.visibility,

    -- timestamps + provenance
    m.measure_at,
    m.measure_date,
    m.ingest_at,
    m.ingest_source

from measurements m
left join stations s using (station_id)
