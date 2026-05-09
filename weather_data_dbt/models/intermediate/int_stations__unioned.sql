{{ config(materialized='table') }}

{#
    int_stations__unioned
    ---------------------

    Union of CWA weather stations and agricultural rain-fall stations into
    a single station dimension, with origin tracking via `station_source`.
    Some station_ids may exist in both sources (rare but possible) — when
    that happens, CWA wins over rain-fall (CWA provides richer metadata).

    Output is one row per station_id, used as the input to dim_stations.
#}

with weather as (
    select
        station_id,
        'cwa' as station_source,
        station_type,
        station_name,
        station_name_en,
        county_name,
        cast(null as string) as town_name,
        cast(null as string) as town_code,
        cast(null as string) as city_code,        -- CWA does not split town_code from county_code at staging
        location,
        notes,
        original_station_id,
        new_station_id,
        station_status,
        station_altitude,
        station_longitude,
        station_latitude,
        start_at,
        end_at
    from {{ ref('stg_weather_stations') }}
),

rain_fall as (
    select
        station_id,
        'rain_fall' as station_source,
        station_type,
        station_name,
        cast(null as string) as station_name_en,
        city_name as county_name,                 -- agricultural source uses 縣市/CITY for what CWA calls county
        town_name,
        town_code,
        city_code,
        cast(null as string) as location,
        cast(null as string) as notes,
        cast(null as string) as original_station_id,
        cast(null as string) as new_station_id,
        cast(null as string) as station_status,
        cast(null as float64) as station_altitude,
        station_longitude,
        station_latitude,
        cast(null as date) as start_at,
        cast(null as date) as end_at
    from {{ ref('stg_rain_fall_stations') }}
),

combined as (
    select * from weather
    union all
    select * from rain_fall
),

prioritized as (
    select * except(rn)
    from (
        select
            *,
            row_number() over (
                partition by station_id
                -- CWA wins over rain_fall on collision
                order by case when station_source = 'cwa' then 0 else 1 end
            ) as rn
        from combined
    )
    where rn = 1
)

select * from prioritized
