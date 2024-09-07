{%- set has_no_negative = ['air_temperature', 'air_pressure', 'relative_humidity', 'wind_speed', 'wind_direction', 'wind_direction_gust', 'peak_gust_speed', 'precipitation', 'sunshine_duration_10Min', 'uv_index'] -%}
{%- set has_null = ['visibility', 'weather_status']-%}

with source as (
    select * from {{ source("measurements", "WEATHER_EXT_TABLE") }}
),

renamed AS (
    select 
        -- ids
        nested_json_layer2.value:StationId::varchar as station_id,
        
        -- numerics
        nested_json_layer2.value:WeatherElement:AirTemperature::float as air_temperature,
        nested_json_layer2.value:WeatherElement:AirPressure::float as air_pressure,
        nested_json_layer2.value:WeatherElement:RelativeHumidity::float as relative_humidity,
        nested_json_layer2.value:WeatherElement:WindSpeed::float as wind_speed,
        nested_json_layer2.value:WeatherElement:WindDirection::float as wind_direction,
        nested_json_layer2.value:WeatherElement:GustInfo:Occurred_at:WindDirection::float as wind_direction_gust,
        nested_json_layer2.value:WeatherElement:GustInfo:PeakGustSpeed::float as peak_gust_speed,
        nested_json_layer2.value:WeatherElement:Now:Precipitation::float as precipitation,
        nested_json_layer2.value:WeatherElement:SunshineDuration::float as sunshine_duration_10Min,
        nested_json_layer2.value:WeatherElement:UVIndex::float as uv_index,

        -- strings
        nested_json_layer2.value:StationName::varchar as station_name,
        nested_json_layer2.value:WeatherElement:Weather::varchar as weather_status,
        nested_json_layer2.value:WeatherElement:VisibilityDescription::varchar as visibility,
        (
            case 
                when STARTSWITH(nested_json_layer2.value:StationId, '46') THEN '有人站'
                when STARTSWITH(nested_json_layer2.value:StationId, 'C0') THEN '自動站'
                when STARTSWITH(nested_json_layer2.value:StationId, 'C1') THEN '自動站'
                ELSE '農業雨量站'
            end
        ) as station_type,

        -- timestamp 
        TO_TIMESTAMP(nested_json_layer2.value:ObsTime:DateTime) as measure_at,
        
    from source,
        lateral flatten(input => VALUE:records) nested_json_layer1,
        lateral flatten(input => nested_json_layer1.value) nested_json_layer2,
), 
null_negative_processed AS (
    SELECT

        -- ids
        station_id,

        -- numerics
        {% for numerics_column in has_no_negative -%}
            
            {{ negative_to_null( numerics_column ) }} AS {{ numerics_column }},
            
        {%- endfor%}
        
        -- strings
        station_name,

        
        {% for string_column in has_null -%}

            {{ na_tag_to_null( string_column ) }} AS {{ string_column }},
        
        {%- endfor%}

        station_type,
        
        -- timestamp
        measure_at

    FROM renamed
    order by measure_at
), duplicated_marked as (
    select 
        * ,
        ROW_NUMBER() over (PARTITION BY station_id, measure_at ORDER BY measure_at) as duplicated_count,
    from null_negative_processed 
), duplicated_removed as (
    select * from duplicated_marked where duplicated_count = 1
)


select 
    *
    exclude duplicated_count
from duplicated_removed