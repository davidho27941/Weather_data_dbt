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
    -- Cast city_code / town_code to STRING. Bronze's bq autodetect inferred
    -- INT64 from the all-numeric values, but the union with CWA stations
    -- (where these codes are STRING or NULL) needs aligned types, and
    -- treating identifier codes as numeric is the wrong abstraction anyway.
    cast(city_code as string) as city_code,
    city_name,
    cast(town_code as string) as town_code,
    town_name,
    station_latitude,
    station_longitude,
    ingest_at
from bronze
