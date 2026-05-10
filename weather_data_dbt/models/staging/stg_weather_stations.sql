{{ config(materialized='view') }}

{#
    stg_weather_stations
    --------------------
    Bronze weather_stations is already deduplicated (latest snapshot per
    station_id) and types are aligned via the canonical schema. Staging is
    a passthrough with documentation + the station_type classification.
#}

with bronze as (
    select * from {{ source('weather_raw', 'weather_stations') }}
)

select
    station_id,
    {{ classify_station_type('station_id') }} as station_type,
    original_station_id,
    new_station_id,
    station_status,
    station_name,
    station_name_en,
    county_name,
    location,
    notes,
    station_altitude,
    station_longitude,
    station_latitude,
    start_at,
    end_at,
    ingest_source,
    ingest_at
from bronze
