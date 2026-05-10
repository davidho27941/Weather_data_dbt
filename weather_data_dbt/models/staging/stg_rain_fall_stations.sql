{{ config(materialized='view') }}

{#
    stg_rain_fall_stations
    ----------------------
    Bronze rain_fall_stations is already deduplicated (latest snapshot per
    station_id). Staging is a passthrough with documentation; station_type
    is hard-coded since this table only contains agricultural rain-fall
    stations.
#}

with bronze as (
    select * from {{ source('weather_raw', 'rain_fall_stations') }}
)

select
    station_id,
    '農業雨量站' as station_type,
    station_name,
    city_code,
    city_name,
    town_code,
    town_name,
    station_latitude,
    station_longitude,
    ingest_at
from bronze
