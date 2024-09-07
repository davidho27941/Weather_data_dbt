with
    rain_fall_station as (select * from {{ ref("stg_rain_fall_stn__station") }}),
    weather_station as (select * from {{ ref("stg_weather_stn__station") }}),
    geo_coordinates_tw97 as (
        select * from {{ ref("stg_measurements__station_geo_TW97") }}
    ),
    joined_rain_fall_weather_station as (
        select
            -- -- ids
            coalesce(
                rain_fall_station.station_id, weather_station.station_id
            ) as station_id,
            weather_station.original_station_id,
            weather_station.new_station_id,
            rain_fall_station.city_code,
            rain_fall_station.town_code,

            -- -- strings
            weather_station.station_status,
            coalesce(
                rain_fall_station.station_name, weather_station.station_name
            ) as station_name,
            weather_station.station_name_en,
            coalesce(
                rain_fall_station.city_name, weather_station.country_name
            ) as city_name,
            rain_fall_station.town_name as town_name,
            weather_station.location as location,
            weather_station.notes as notes,

            -- -- numerics
            weather_station.station_altitude as station_altitude,
            coalesce(
                weather_station.station_longitude, rain_fall_station.station_longitude
            ) as station_longitude,
            coalesce(
                weather_station.station_latitude, rain_fall_station.station_latitude
            ) as station_latitude,

            -- timestamp
            weather_station.start_at,
            weather_station.end_at,

        from rain_fall_station
        full outer join
            weather_station on rain_fall_station.station_id = weather_station.station_id
    ),
    joined_with_all_geo_coordinate_tw97 as (
        select
            -- ids
            coalesce(
                joined_rain_fall_weather_station.station_id,
                geo_coordinates_tw97.station_id
            ) as station_id,
            joined_rain_fall_weather_station.original_station_id,
            joined_rain_fall_weather_station.new_station_id,
            coalesce(
                joined_rain_fall_weather_station.city_code,
                geo_coordinates_tw97.country_code
            ) as country_code,
            coalesce(
                joined_rain_fall_weather_station.town_code,
                geo_coordinates_tw97.town_code
            ) as town_code,

            -- -- strings
            joined_rain_fall_weather_station.station_status,
            joined_rain_fall_weather_station.station_name,
            joined_rain_fall_weather_station.station_name_en,
            coalesce(
                joined_rain_fall_weather_station.city_name,
                geo_coordinates_tw97.country_name
            ) as country_name,
            coalesce(
                joined_rain_fall_weather_station.town_name,
                geo_coordinates_tw97.town_name
            ) as town_name,
            joined_rain_fall_weather_station.location,
            joined_rain_fall_weather_station.notes,
            geo_coordinates_tw97.coordinate_format as tw97_coordinate_format,
            (
                case 
                    when STARTSWITH(joined_rain_fall_weather_station.station_id, '46') THEN '有人站'
                    when STARTSWITH(joined_rain_fall_weather_station.station_id, 'C0') THEN '自動站'
                    when STARTSWITH(joined_rain_fall_weather_station.station_id, 'C1') THEN '自動站'
                    ELSE '農業雨量站'
                end
            ) as station_type,

            -- numerics
            joined_rain_fall_weather_station.station_altitude,
            joined_rain_fall_weather_station.station_longitude
            as station_longitude_wgs87,
            joined_rain_fall_weather_station.station_latitude as station_latitude_wgs87,
            geo_coordinates_tw97.station_longitude as station_longitude_tw97,
            geo_coordinates_tw97.station_latitude as station_latitude_tw97,

            -- -- timestamp
            joined_rain_fall_weather_station.start_at,
            joined_rain_fall_weather_station.end_at,

        from joined_rain_fall_weather_station
        full outer join
            geo_coordinates_tw97
            on joined_rain_fall_weather_station.station_id
            = geo_coordinates_tw97.station_id
    )

select *
from joined_with_all_geo_coordinate_tw97
