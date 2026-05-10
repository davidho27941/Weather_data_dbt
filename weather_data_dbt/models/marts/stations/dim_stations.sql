{{ config(materialized='table') }}

{#
    dim_stations
    ------------
    Final station dimension. One row per station_id, with all metadata
    needed by ML training datasets:

      - identity: station_id, original_station_id, new_station_id
      - classification: station_type, station_status, station_source
      - geography: county_name, town_name, latitude/longitude/altitude
      - lifecycle: start_at, end_at

    Used by every fct_measurements_* mart for station context.
#}

with unioned as (
    select * from {{ ref('int_stations__unioned') }}
)

select
    station_id,
    original_station_id,
    new_station_id,
    station_name,
    station_name_en,
    station_type,
    station_status,
    station_source,                         -- 'cwa' or 'rain_fall'
    county_name,
    town_name,
    town_code,
    city_code,
    location,
    notes,
    station_altitude,
    station_longitude,
    station_latitude,
    start_at,
    end_at
from unioned
