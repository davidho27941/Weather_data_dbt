with source AS (
    SELECT * FROM {{ source('rain_fall_stn', 'RAIN_FALL_STN_EXT_TABLE') }}
),

ranamed AS (
    SELECT 
        -- id
        nested_json.value:Station_ID::varchar as station_id,
        nested_json.value:CITY_SN::varchar AS city_code,
        nested_json.value:TOWN_SN::varchar AS town_code,

        -- strings
        nested_json.value:Station_name::varchar as station_name,
        nested_json.value:Station_Latitude::number(10,5) AS station_latitude,
        nested_json.value:Station_Longitude::number(10,5) AS station_longitude,
        nested_json.value:CITY::varchar AS city_name,
        nested_json.value:TOWN::varchar AS town_name,
    FROM source,
        lateral flatten(input => VALUE:Data) AS nested_json
)

SELECT * FROM ranamed