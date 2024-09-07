with source as (
    select * from {{ source("measurements", "WEATHER_EXT_TABLE") }}
),

renamed AS (
    select 
        -- ids
        DISTINCT nested_json_layer2.value:StationId::varchar as station_id,

        -- numerics
        nested_json_layer2.value:GeoInfo:Coordinates[0]:StationLatitude::float AS station_latitude,
        nested_json_layer2.value:GeoInfo:Coordinates[0]:StationLongitude::float AS station_longitude,
        nested_json_layer2.value:GeoInfo:StationAltitude::float AS station_altitude,

        -- strings
        nested_json_layer2.value:GeoInfo:CountyName::varchar AS country_name,
        nested_json_layer2.value:GeoInfo:CountyCode::varchar AS country_code,
        nested_json_layer2.value:GeoInfo:TownName::varchar AS town_name,
        nested_json_layer2.value:GeoInfo:TownCode::varchar AS town_code,
        nested_json_layer2.value:GeoInfo:Coordinates[0]:CoordinateFormat::varchar AS coordinate_format,
        
        (
            case 
                when STARTSWITH(nested_json_layer2.value:StationId, '46') THEN '有人站'
                when STARTSWITH(nested_json_layer2.value:StationId, 'C0') THEN '自動站'
                when STARTSWITH(nested_json_layer2.value:StationId, 'C1') THEN '自動站'
                ELSE '農業雨量站'
            end
        ) as station_type,

    from source,
        lateral flatten(input => VALUE:records) nested_json_layer1,
        lateral flatten(input => nested_json_layer1.value) nested_json_layer2,
)

select * from renamed