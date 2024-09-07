with source as (
    select * from {{ source("weather_stn", "WEATHER_STN_EXT_TABLE") }}
),
renamed as (
    select

        -- ids
        nested_json.value:StationID::varchar as station_id,
        (
            CASE 
                WHEN nested_json.value:OriginalStationID = '' THEN NULL
                ELSE nested_json.value:OriginalStationID::varchar
            END
        ) AS original_station_id,
        (
            CASE 
                WHEN nested_json.value:NewStationID = '' THEN NULL
                ELSE nested_json.value:NewStationID::varchar
            END
        ) AS new_station_id,

        -- strings
        nested_json.value:status::varchar as station_status,
        nested_json.value:StationName::varchar as station_name,
        nested_json.value:StationNameEN::varchar as station_name_en,
        nested_json.value:CountyName::varchar as country_name,
        nested_json.value:Location::varchar as location,
        (
            CASE 
                WHEN nested_json.value:Notes = '' THEN NULL
                ELSE nested_json.value:Notes::varchar
            END
        ) AS notes,

        -- numerics
        nested_json.value:StationAltitude::float as station_altitude,
        nested_json.value:StationLongitude::float as station_longitude,
        nested_json.value:StationLatitude::float as station_latitude,

        -- timestamps
        (
            CASE 
                WHEN nested_json.value:StationStartDate = '' THEN NULL
                ELSE nested_json.value:StationStartDate::date
            END
        ) AS start_at,
        (
            CASE 
                WHEN nested_json.value:StationEndDate = '' THEN NULL
                ELSE nested_json.value:StationEndDate::date
            END
        ) AS end_at,

    from
        source,
        lateral flatten(
            input => value:records:data:stationStatus:station
        ) nested_json
)

select *
from renamed
